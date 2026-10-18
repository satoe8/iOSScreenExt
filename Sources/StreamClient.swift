// StreamClient.swift
// Wire protocol client for HostService (see Transport.h on the PC for the authoritative spec).
// All integers on the wire are little-endian.
//
//   MsgHeader (12): u32 magic 0x53444449, u8 version(1), u8 type, u16 flags, u32 payloadLen
//   VIDEO payload : u32 frameNumber, u64 ptsUs, u16 cropX, cropY, cropW, cropH, then Annex-B bytes
//   HELLO payload : u16 codec, codedW, codedH, cropX, cropY, cropW, cropH, fps
//   TOUCH payload : u8 id, u8 phase, u16 x, u16 y, u16 pressure
//
// Connection modes:
//   .listenTCP  - the iPhone listens, the PC connects (USB via usbmuxd/iproxy: PC runs
//                 `HostService --connect 127.0.0.1:<localPort>`; or LAN: `--connect <phone-ip>:<port>`)
//   .connectTCP - the iPhone connects to the PC running `HostService --listen <port>`
//   .udp        - the iPhone sends datagrams to `HostService --udp <port>`; video comes back fragmented
//
// Callbacks are invoked on the client's private serial queue.

import Foundation
import Network

struct StreamInfo {
    var codedW = 2556, codedH = 1180
    var cropX = 0, cropY = 0, cropW = 2556, cropH = 1179
    var fps = 60
}

struct VideoPacket {
    let frameNumber: UInt32
    let ptsUs: UInt64
    let flags: UInt16
    let annexB: Data
    var isKeyFrame: Bool { flags & 0x1 != 0 }
    var isDiscontinuity: Bool { flags & 0x8 != 0 }
}

enum StreamMode {
    case listenTCP(port: UInt16)
    case connectTCP(host: String, port: UInt16)
    case udp(host: String, port: UInt16)
}

enum TouchPhase: UInt8 { case down = 0, move = 1, up = 2, cancel = 3 }

// MARK: - little-endian helpers

private extension Data {
    func u8(_ o: Int) -> UInt8 { self[startIndex + o] }
    func u16(_ o: Int) -> UInt16 { UInt16(u8(o)) | (UInt16(u8(o + 1)) << 8) }
    func u32(_ o: Int) -> UInt32 { UInt32(u16(o)) | (UInt32(u16(o + 2)) << 16) }
    func u64(_ o: Int) -> UInt64 { UInt64(u32(o)) | (UInt64(u32(o + 4)) << 32) }
    func slice(_ from: Int, _ to: Int) -> Data { Data(self[(startIndex + from)..<(startIndex + to)]) }

    mutating func put8(_ v: UInt8) { append(v) }
    mutating func put16(_ v: UInt16) { append(UInt8(v & 0xFF)); append(UInt8(v >> 8)) }
    mutating func put32(_ v: UInt32) { put16(UInt16(v & 0xFFFF)); put16(UInt16(v >> 16)) }
    mutating func put64(_ v: UInt64) { put32(UInt32(v & 0xFFFF_FFFF)); put32(UInt32(v >> 32)) }
}

private let kMagic: UInt32 = 0x5344_4449
private let kUdpMagic: UInt16 = 0x4455
private let kHeaderSize = 12

private enum MsgType: UInt8 {
    case video = 1, hello = 2, keyframeReq = 3, touch = 4, ping = 5, pong = 6, pen = 7
}

private func nowUs() -> UInt64 { DispatchTime.now().uptimeNanoseconds / 1000 }

// MARK: - client

final class StreamClient {
    var onHello: ((StreamInfo) -> Void)?
    var onVideo: ((VideoPacket) -> Void)?
    var onState: ((String) -> Void)?
    var onRTT: ((Double) -> Void)?          // milliseconds
    var onConnectionChanged: ((Bool) -> Void)?   // true once the transport is up, false when it drops

    private let q = DispatchQueue(label: "stream.net", qos: .userInteractive)
    private var listener: NWListener?
    private var conn: NWConnection?
    private var mode: StreamMode?
    private var isUDP = false
    private var rx = Data()
    private var pingTimer: DispatchSourceTimer?
    private var lastKeyReq: UInt64 = 0
    private var lastRxUs: UInt64 = 0
    private var alsoListenPort: UInt16?
    private var isConnected = false

    // UDP reassembly
    private struct Pending { var count: Int; var got: Int; var parts: [Data?] }
    private var pending: [UInt32: Pending] = [:]

    // MARK: public API

    func start(_ mode: StreamMode) {
        q.async { self.startLocked(mode) }
    }

    /// Drop the current connection and begin again with the last mode (e.g. after the app returns from the background).
    func restart() {
        q.async {
            guard let m = self.mode else { return }
            self.startLocked(m)
        }
    }

    private func startLocked(_ mode: StreamMode) {
        teardown()
        self.mode = mode
        switch mode {
        case .listenTCP(let port):            startListener(port)
        case .connectTCP(let host, let port): connectTCP(host, port)
        case .udp(let host, let port):        startUDP(host, port)
        }
        if let p = alsoListenPort, listener == nil { startListener(p, announce: false) }
    }

    /// Keep a TCP listener open IN ADDITION to the active connection. Automatic mode uses this so the PC can reach
    /// the app through the USB tunnel (PC connects in) while the app also searches for the PC over Wi-Fi.
    /// Pass nil to stop doing that (takes effect the next time a mode is started).
    func setAlsoListen(port: UInt16?) {
        q.async {
            self.alsoListenPort = port
            if let p = port, self.listener == nil { self.startListener(p, announce: false) }
        }
    }

    func stop() {
        q.async {
            self.mode = nil
            self.teardown()
            self.onState?("Stopped")
        }
    }

    /// Ask the host for an IDR. Rate-limited to 4 per second.
    func sendKeyframeRequest() {
        q.async {
            let t = nowUs()
            guard t - self.lastKeyReq > 250_000 else { return }
            self.lastKeyReq = t
            self.send(self.message(.keyframeReq, Data()))
        }
    }

    /// x, y are 0...1 inside the visible (cropped) video area; pressure 0...1.
    func sendTouch(id: UInt8, phase: TouchPhase, x: Double, y: Double, pressure: Double) {
        func q16(_ v: Double) -> UInt16 { UInt16((min(1, max(0, v)) * 65535).rounded()) }
        var p = Data()
        p.put8(id); p.put8(phase.rawValue); p.put16(q16(x)); p.put16(q16(y)); p.put16(q16(pressure))
        let payload = p
        q.async { self.send(self.message(.touch, payload)) }
    }

    /// Apple Pencil sample, sent as a real pen (Windows Ink). x, y, pressure are 0...1 (x, y inside the visible
    /// area); tilt is in degrees (-90...90); rotation in degrees. Wire format: see PenPayload in Transport.h.
    func sendPen(phase: TouchPhase, x: Double, y: Double, pressure: Double, tiltX: Double, tiltY: Double, rotation: Double) {
        func q16(_ v: Double) -> UInt16 { UInt16((min(1, max(0, v)) * 65535).rounded()) }
        func deg(_ v: Double) -> UInt16 {                      // signed degrees, clamped, two's complement
            let d = Int(min(90, max(-90, v)).rounded())
            return UInt16(bitPattern: Int16(clamping: d))
        }
        var p = Data()
        p.put8(phase.rawValue); p.put8(0)                      // flags: barrel/eraser not available on Apple Pencil
        p.put16(q16(x)); p.put16(q16(y)); p.put16(q16(pressure))
        p.put16(deg(tiltX)); p.put16(deg(tiltY))
        let r = ((Int(rotation.rounded()) % 360) + 360) % 360
        p.put16(UInt16(r))
        let payload = p
        q.async { self.send(self.message(.pen, payload)) }
    }

    // MARK: lifecycle

    private func setConnected(_ v: Bool) {
        guard v != isConnected else { return }
        isConnected = v
        onConnectionChanged?(v)
    }

    private func teardown() {
        setConnected(false)
        listener?.cancel(); listener = nil
        conn?.cancel(); conn = nil
        pingTimer?.cancel(); pingTimer = nil
        rx = Data()
        pending.removeAll()
        isUDP = false
    }

    private func startListener(_ port: UInt16, announce: Bool = true) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.allowLocalEndpointReuse = true
        guard let p = NWEndpoint.Port(rawValue: port), let l = try? NWListener(using: params, on: p) else {
            onState?("Could not listen on \(port)")
            return
        }
        l.stateUpdateHandler = { [weak self] st in
            if case .failed(let e) = st { self?.onState?("Listener failed: \(e)") }
            if announce, case .ready = st { self?.onState?("Listening on \(port)…") }
        }
        l.newConnectionHandler = { [weak self] c in
            self?.q.async { self?.adopt(c) }
        }
        l.start(queue: q)
        listener = l
        if announce { onState?("Listening on \(port)…") }
    }

    private func connectTCP(_ host: String, _ port: UInt16) {
        guard let p = NWEndpoint.Port(rawValue: port) else { return }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let c = NWConnection(host: NWEndpoint.Host(host), port: p, using: NWParameters(tls: nil, tcp: tcp))
        onState?("Connecting to \(host):\(port)…")
        adopt(c)
    }

    private func startUDP(_ host: String, _ port: UInt16) {
        guard let p = NWEndpoint.Port(rawValue: port) else { return }
        isUDP = true
        let c = NWConnection(host: NWEndpoint.Host(host), port: p, using: .udp)
        onState?("UDP → \(host):\(port)…")
        adopt(c)
    }

    private func adopt(_ c: NWConnection) {
        conn?.cancel()
        conn = c
        rx = Data()
        pending.removeAll()
        c.stateUpdateHandler = { [weak self, weak c] st in
            guard let self = self, let c = c, self.conn === c else { return }
            switch st {
            case .ready:
                self.onState?(self.isUDP ? "UDP ready" : "Connected")
                self.lastRxUs = nowUs()
                self.setConnected(true)
                self.startPing()
                self.sendPing()                        // for UDP this is also the "hello" that registers us
                self.isUDP ? self.receiveDatagram(c) : self.receiveStream(c)
            case .failed(let e):
                self.onState?("Connection failed: \(e)")
                self.connectionLost()
            case .waiting(let e):
                self.onState?("Waiting: \(e)")
            default: break
            }
        }
        c.start(queue: q)
    }

    private func connectionLost() {
        setConnected(false)
        pingTimer?.cancel(); pingTimer = nil
        conn?.cancel(); conn = nil
        guard let m = mode else { return }
        switch m {
        case .connectTCP(let host, let port):
            q.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self = self, self.conn == nil, self.mode != nil else { return }
                self.connectTCP(host, port)
            }
        case .udp(let host, let port):
            q.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self = self, self.conn == nil, self.mode != nil else { return }
                self.startUDP(host, port)
            }
        case .listenTCP:
            onState?("Client disconnected; listening…")
        }
    }

    private func startPing() {
        pingTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        pingTimer = t
    }

    /// Once a second: keep-alive ping + watchdog. The host answers every ping, so 5 s of silence means the
    /// link or the PC is gone (or the app was suspended): reconnect instead of waiting on a dead socket.
    private func tick() {
        if conn != nil, lastRxUs != 0, nowUs() &- lastRxUs > 5_000_000 {
            onState?("No data for 5 s - reconnecting")
            connectionLost()
            return
        }
        sendPing()
    }

    private func sendPing() {
        var p = Data()
        p.put64(nowUs())
        send(message(.ping, p))
    }

    // MARK: sending

    private func message(_ type: MsgType, _ payload: Data) -> Data {
        var d = Data()
        d.put32(kMagic); d.put8(1); d.put8(type.rawValue); d.put16(0); d.put32(UInt32(payload.count))
        d.append(payload)
        return d
    }

    private func send(_ msg: Data) {
        guard let c = conn else { return }
        if isUDP {
            // client -> host datagram: UdpHeader(kind 1, one fragment) + complete message
            var d = Data()
            d.put16(kUdpMagic); d.put8(1); d.put8(0); d.put32(0); d.put16(0); d.put16(1)
            d.append(msg)
            c.send(content: d, completion: .contentProcessed { _ in })
        } else {
            c.send(content: msg, completion: .contentProcessed { _ in })
        }
    }

    // MARK: TCP receive / framing

    private func receiveStream(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self, weak c] data, _, isComplete, error in
            guard let self = self, let c = c, self.conn === c else { return }
            if let d = data, !d.isEmpty {
                self.lastRxUs = nowUs()
                self.rx.append(d)
                if !self.parseStream() { c.cancel(); self.connectionLost(); return }
            }
            if error != nil || isComplete {
                self.connectionLost()
                return
            }
            self.receiveStream(c)
        }
    }

    /// Returns false on a framing error (caller drops the connection).
    private func parseStream() -> Bool {
        while rx.count >= kHeaderSize {
            guard rx.u32(0) == kMagic, rx.u8(4) == 1 else { return false }
            let len = Int(rx.u32(8))
            guard len <= 16 * 1024 * 1024 else { return false }
            guard rx.count >= kHeaderSize + len else { break }

            let type = rx.u8(5)
            let flags = rx.u16(6)
            let payload = rx.slice(kHeaderSize, kHeaderSize + len)
            rx = rx.slice(kHeaderSize + len, rx.count)
            handle(type: type, flags: flags, payload: payload)
        }
        return true
    }

    // MARK: UDP receive / reassembly

    private func receiveDatagram(_ c: NWConnection) {
        c.receiveMessage { [weak self, weak c] data, _, _, error in
            guard let self = self, let c = c, self.conn === c else { return }
            if let d = data { self.lastRxUs = nowUs(); self.handleDatagram(d) }
            if error != nil { self.connectionLost(); return }
            self.receiveDatagram(c)
        }
    }

    private func handleDatagram(_ d: Data) {
        guard d.count >= 12, d.u16(0) == kUdpMagic, d.u8(2) == 0 else { return }
        let seq = d.u32(4)
        let idx = Int(d.u16(8)), cnt = Int(d.u16(10))
        guard cnt >= 1, idx < cnt else { return }
        let body = d.slice(12, d.count)

        if cnt == 1 { handleWholeMessage(body); return }

        var p = pending[seq] ?? Pending(count: cnt, got: 0, parts: Array(repeating: nil, count: cnt))
        guard p.count == cnt else { return }
        if p.parts[idx] == nil { p.parts[idx] = body; p.got += 1 }

        if p.got == p.count {
            var whole = Data()
            for part in p.parts { if let part = part { whole.append(part) } }
            pending[seq] = nil
            // Anything older that never completed is lost: ask for a fresh IDR.
            let stale = pending.keys.filter { $0 < seq }
            if !stale.isEmpty {
                stale.forEach { pending[$0] = nil }
                sendKeyframeRequest()
            }
            handleWholeMessage(whole)
        } else {
            pending[seq] = p
            if pending.count > 8 {                      // too many half-finished frames: give up on the oldest
                if let oldest = pending.keys.min() { pending[oldest] = nil }
                sendKeyframeRequest()
            }
        }
    }

    private func handleWholeMessage(_ m: Data) {
        guard m.count >= kHeaderSize, m.u32(0) == kMagic, m.u8(4) == 1 else { return }
        let len = Int(m.u32(8))
        guard m.count >= kHeaderSize + len else { return }
        handle(type: m.u8(5), flags: m.u16(6), payload: m.slice(kHeaderSize, kHeaderSize + len))
    }

    // MARK: message dispatch

    private func handle(type: UInt8, flags: UInt16, payload: Data) {
        guard let t = MsgType(rawValue: type) else { return }   // unknown types: ignore (forward compatible)
        switch t {
        case .hello where payload.count >= 16:
            var info = StreamInfo()
            info.codedW = Int(payload.u16(2));  info.codedH = Int(payload.u16(4))
            info.cropX  = Int(payload.u16(6));  info.cropY  = Int(payload.u16(8))
            info.cropW  = Int(payload.u16(10)); info.cropH  = Int(payload.u16(12))
            info.fps    = Int(payload.u16(14))
            onHello?(info)

        case .video where payload.count > 20:
            onVideo?(VideoPacket(frameNumber: payload.u32(0), ptsUs: payload.u64(4), flags: flags,
                                 annexB: payload.slice(20, payload.count)))

        case .pong where payload.count >= 16:
            let sent = payload.u64(0)
            let now = nowUs()
            if now >= sent { onRTT?(Double(now - sent) / 1000.0) }

        default: break
        }
    }
}
