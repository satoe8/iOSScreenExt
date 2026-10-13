// ContentView.swift
// Glue: StreamClient -> (decode queue) VideoDecoder -> VideoRenderer, touch back-channel, automatic
// connection (saved host + LAN discovery + auto-reconnect), and a tiny HUD.
//
// Requires iOS 16+. Keep your project's @main App struct pointing at ContentView().

import SwiftUI
import UIKit

final class StreamModel: ObservableObject {
    @Published var status = "Idle"
    @Published var running = false
    @Published var connected = false
    @Published var fps = 0
    @Published var rttMs = 0.0
    @Published var hostName = ""

    let client = StreamClient()
    let decoder = VideoDecoder()
    let renderer = VideoRenderer()

    // Decoding runs on its own queue so a slow/blocked decoder can never stop the socket from being read
    // (a stalled receive loop fills the TCP window and freezes the whole stream).
    private let decodeQueue = DispatchQueue(label: "decode", qos: .userInteractive)
    private let stateLock = NSLock()                    // guards the fields below
    private var frameCount = 0
    private var backlog = 0
    private var backlogDrops = 0
    private var connectedFlag = false
    private var lastMainTick = DispatchTime.now().uptimeNanoseconds

    private var mainStalled = false                     // watchdog queue only
    private var touchesSent = 0                         // main thread only
    private var timer: Timer?
    private var watchdog: DispatchSourceTimer?
    private var autoTask: Task<Void, Never>?
    private var tick = 0

    init() {
        client.onState = { [weak self] s in
            AppLog.log("net: \(s)")
            DispatchQueue.main.async { self?.status = s }
        }
        client.onRTT = { [weak self] r in DispatchQueue.main.async { self?.rttMs = r } }
        client.onConnectionChanged = { [weak self] c in
            guard let self = self else { return }
            AppLog.log("connected=\(c)")
            self.stateLock.lock(); self.connectedFlag = c; self.stateLock.unlock()
            DispatchQueue.main.async { self.connected = c }
        }

        // HELLO is the first message on every connection and again after a PC-side resolution change.
        // The reset is queued on the decode queue so it stays ordered with the frames around it.
        client.onHello = { [weak self] info in
            guard let self = self else { return }
            AppLog.log("hello coded \(info.codedW)x\(info.codedH) crop \(info.cropW)x\(info.cropH) @\(info.fps)")
            self.renderer.setStreamInfo(info)
            self.decodeQueue.async { self.decoder.reset() }
        }
        client.onVideo = { [weak self] pkt in self?.enqueueDecode(pkt) }

        decoder.onNeedKeyframe = { [weak self] in self?.client.sendKeyframeRequest() }
        decoder.onLog = { s in AppLog.log("decoder: \(s)") }
        decoder.onFrame = { [weak self] pb, _ in
            guard let self = self else { return }
            self.renderer.enqueue(pb)
            self.stateLock.lock(); self.frameCount += 1; self.stateLock.unlock()
        }

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.stateLock.lock()
            let n = self.frameCount; self.frameCount = 0
            let drops = self.backlogDrops, backlog = self.backlog
            self.stateLock.unlock()
            self.fps = n
            self.tick += 1
            if self.running && self.tick % 5 == 0 {
                AppLog.log("alive fps=\(n) backlog=\(backlog) backlogDrops=\(drops) touches=\(self.touchesSent) connected=\(self.connected)")
            }
        }
        startWatchdog()
    }

    deinit {
        timer?.invalidate()
        watchdog?.cancel()
    }

    // MARK: decode pipeline

    private func enqueueDecode(_ pkt: VideoPacket) {
        stateLock.lock()
        if backlog >= 3 && !pkt.isKeyFrame {
            // Decoder is behind: skip stale P-frames (the decoder notices the number gap and asks for an IDR).
            backlogDrops += 1
            stateLock.unlock()
            return
        }
        backlog += 1
        stateLock.unlock()

        decodeQueue.async { [weak self] in
            guard let self = self else { return }
            self.decoder.decode(pkt)
            self.stateLock.lock(); self.backlog -= 1; self.stateLock.unlock()
        }
    }

    // MARK: main-thread watchdog (writes to ScreenExt.log if the UI thread hangs)

    private func startWatchdog() {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "watchdog", qos: .utility))
        t.schedule(deadline: .now() + 0.25, repeating: 0.25)
        t.setEventHandler { [weak self] in
            guard let self = self else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.stateLock.lock(); self.lastMainTick = DispatchTime.now().uptimeNanoseconds; self.stateLock.unlock()
            }
            self.stateLock.lock(); let last = self.lastMainTick; let backlog = self.backlog; self.stateLock.unlock()
            let stall = Double(DispatchTime.now().uptimeNanoseconds &- last) / 1e9
            if stall > 1.0 && !self.mainStalled {
                self.mainStalled = true
                AppLog.log("MAIN THREAD STALLED for > 1 s (decode backlog \(backlog))")
            } else if stall < 0.5 && self.mainStalled {
                self.mainStalled = false
                AppLog.log("main thread recovered")
            }
        }
        t.resume()
        watchdog = t
    }

    // MARK: connection control

    func start(_ choice: ConnectionChoice, host: String, port: UInt16) {
        autoTask?.cancel()
        running = true
        Task { @MainActor in UIApplication.shared.isIdleTimerDisabled = true }   // don't dim/lock while streaming
        AppLog.log("start \(choice) host='\(host)' port=\(port)")

        switch choice {
        case .listen:  client.start(.listenTCP(port: port))
        case .connect: client.start(.connectTCP(host: host, port: port))
        case .udp:     client.start(.udp(host: host, port: port))
        case .auto:    startAuto(savedHost: host, port: port)
        }
    }

    func stop() {
        autoTask?.cancel(); autoTask = nil
        client.stop()
        running = false
        connected = false
        Task { @MainActor in UIApplication.shared.isIdleTimerDisabled = false }
        AppLog.log("stopped by user")
    }

    /// App came back to the foreground: sockets may have died while suspended.
    func resume() {
        guard running else { return }
        AppLog.log("app active: restarting the connection")
        client.restart()
    }

    private func isConnectedNow() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return connectedFlag
    }

    /// Automatic mode: try the last-used PC immediately, and whenever we are not connected look for the
    /// PC on the local subnet (unicast discovery) and connect to whatever answers. Reconnects forever.
    private func startAuto(savedHost: String, port: UInt16) {
        if !savedHost.isEmpty {
            client.start(.connectTCP(host: savedHost, port: port))
        }
        autoTask = Task { [weak self] in
            var notConnectedSince = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self = self, !Task.isCancelled else { return }
                if self.isConnectedNow() { notConnectedSince = Date(); continue }

                // Give the saved PC a few seconds before searching (it's usually just still waking up).
                let patience: TimeInterval = savedHost.isEmpty ? 0 : 3
                guard Date().timeIntervalSince(notConnectedSince) >= patience else { continue }

                DispatchQueue.main.async { self.status = "Searching for your PC…" }
                let hosts = await Task.detached(priority: .utility) { HostDiscovery.discover(timeout: 1.5) }.value
                guard !Task.isCancelled, !self.isConnectedNow() else { continue }
                guard let h = hosts.first(where: { !$0.isUDP }) ?? hosts.first else { continue }

                AppLog.log("discovered \(h.address):\(h.port) '\(h.name)' udp=\(h.isUDP)")
                UserDefaults.standard.set(h.address, forKey: "host")
                UserDefaults.standard.set(Int(h.port), forKey: "port")
                DispatchQueue.main.async { self.hostName = h.name }
                self.client.start(h.isUDP ? .udp(host: h.address, port: h.port)
                                          : .connectTCP(host: h.address, port: h.port))
                notConnectedSince = Date()      // give the new connection time before searching again
            }
        }
    }

    // MARK: touch

    func touch(_ id: UInt8, _ phase: TouchPhase, _ x: Double, _ y: Double, _ pressure: Double) {
        touchesSent += 1
        if phase != .move || touchesSent <= 5 {
            AppLog.log("touch #\(touchesSent) id=\(id) \(phase) x=\(String(format: "%.3f", x)) y=\(String(format: "%.3f", y))")
        }
        client.sendTouch(id: id, phase: phase, x: x, y: y, pressure: pressure)
    }
}

enum ConnectionChoice: String, CaseIterable, Identifiable {
    case auto    = "Automatic (find my PC on Wi-Fi)"
    case listen  = "USB / Listen (PC connects)"
    case connect = "Connect to a PC address (TCP)"
    case udp     = "Connect to a PC address (UDP)"
    var id: String { rawValue }
}

struct ContentView: View {
    @StateObject private var model = StreamModel()
    @Environment(\.scenePhase) private var scenePhase

    // Remembered between launches (also written by automatic discovery).
    @AppStorage("mode") private var modeRaw = ConnectionChoice.auto.rawValue
    @AppStorage("host") private var host = ""
    @AppStorage("port") private var port = 5000
    @AppStorage("autoStart") private var autoStart = true
    @State private var didAutoStart = false

    private var choice: ConnectionChoice { ConnectionChoice(rawValue: modeRaw) ?? .auto }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            MetalVideoView(renderer: model.renderer) { id, phase, x, y, pressure in
                model.touch(id, phase, x, y, pressure)
            }
            .ignoresSafeArea()

            if model.running {
                VStack {
                    HStack(alignment: .top) {
                        Text("\(model.connected ? "●" : "○") \(model.status) · \(model.fps) fps · RTT \(String(format: "%.1f", model.rttMs)) ms")
                            .font(.caption2.monospacedDigit())
                            .padding(6)
                            .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(Color.white)
                        Spacer()
                        Button { model.stop() } label: {
                            Image(systemName: "gearshape.fill").font(.title2)
                                .foregroundStyle(Color.white.opacity(0.7))
                        }
                    }
                    .padding(10)
                    Spacer()
                }
            } else {
                settingsCard
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            // Zero-typing start: connect as soon as the app opens.
            if autoStart && !didAutoStart {
                didAutoStart = true
                startConnection()
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active { model.resume() }
        }
    }

    private func startConnection() {
        model.start(choice, host: host, port: UInt16(clamping: max(1, port)))
    }

    private var settingsCard: some View {
        VStack(spacing: 12) {
            Text("PC Screen Extension").font(.headline)

            Picker("Mode", selection: $modeRaw) {
                ForEach(ConnectionChoice.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            .pickerStyle(.menu)

            switch choice {
            case .auto:
                Text(host.isEmpty ? "The app will look for your PC on this Wi-Fi network."
                                  : "Last PC: \(host). If it moved, the app will search again.")
                    .font(.caption).foregroundStyle(.secondary)
            case .listen:
                TextField("Port", value: $port, format: .number)
                    .textFieldStyle(.roundedBorder).keyboardType(.numberPad)
            case .connect, .udp:
                TextField("PC address", text: $host)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("Port", value: $port, format: .number)
                    .textFieldStyle(.roundedBorder).keyboardType(.numberPad)
            }

            Toggle("Connect automatically at launch", isOn: $autoStart)

            Button("Connect") { startConnection() }
                .buttonStyle(.borderedProminent)

            Text(model.status).font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: 440)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
