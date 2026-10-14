// ContentView.swift
// Consumer UI + connection logic.
//   * Home screen: "ScreenExt", an animated "Searching for PC…" state (or a big Connect button).
//   * While searching, the app does two things at once: it LISTENS for the PC's USB tunnel and it SEARCHES the
//     Wi-Fi network for the PC. Whichever connects first wins; reconnecting is automatic.
//   * All technical settings (manual address, port, TCP/UDP) live in "Advanced" behind the gear icon.
//
// Requires iOS 16+. Keep your project's @main App struct pointing at ContentView().

import SwiftUI
import UIKit

// MARK: - Model

enum ConnectionChoice { case auto, tcp, udp }

final class StreamModel: ObservableObject {
    @Published var status = "Idle"          // technical text: goes to the log, not to the UI
    @Published var running = false
    @Published var connected = false
    @Published var fps = 0
    @Published var rttMs = 0.0
    @Published var hostName = ""            // friendly PC name once discovery found it

    let client = StreamClient()
    let decoder = VideoDecoder()
    let renderer = VideoRenderer()

    static let usbListenPort: UInt16 = 5000     // must match the host's USB device port

    // Decoding runs on its own queue so a slow/blocked decoder can never stop the socket from being read.
    private let decodeQueue = DispatchQueue(label: "decode", qos: .userInteractive)
    private let stateLock = NSLock()            // guards the fields below
    private var frameCount = 0
    private var backlog = 0
    private var backlogDrops = 0
    private var connectedFlag = false
    private var lastMainTick = DispatchTime.now().uptimeNanoseconds

    private var mainStalled = false             // watchdog queue only
    private var touchesSent = 0                 // main thread only
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
            DispatchQueue.main.async {
                self.connected = c
                if !c { self.hostName = "" }
            }
        }

        // HELLO is the first message on every connection and again after a PC-side resolution change.
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
            backlogDrops += 1                       // decoder is behind: skip stale P-frames (it asks for an IDR)
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
        hostName = ""
        Task { @MainActor in UIApplication.shared.isIdleTimerDisabled = true }   // don't dim/lock while streaming
        AppLog.log("start \(choice) host='\(host)' port=\(port)")

        switch choice {
        case .auto:
            startAuto(savedHost: host, port: port)
        case .tcp:
            client.setAlsoListen(port: nil)
            client.start(.connectTCP(host: host, port: port))
        case .udp:
            client.setAlsoListen(port: nil)
            client.start(.udp(host: host, port: port))
        }
    }

    func stop() {
        autoTask?.cancel(); autoTask = nil
        client.stop()
        running = false
        connected = false
        hostName = ""
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

    /// Automatic connection. Two things happen at the same time and the first one to connect wins:
    ///   1. USB: we LISTEN on port 5000, which is where the PC's native USB tunnel connects to;
    ///   2. Wi-Fi: we try the last-used PC immediately and sweep the local network for the PC (unicast
    ///      discovery) every couple of seconds until something answers.
    /// If the connection drops, the same logic simply starts over.
    private func startAuto(savedHost: String, port: UInt16) {
        client.setAlsoListen(port: Self.usbListenPort)
        if !savedHost.isEmpty {
            client.start(.connectTCP(host: savedHost, port: port))
        }
        autoTask = Task { [weak self] in
            var attempting = savedHost          // the PC we are already trying to reach
            var ticksSinceScan = 99
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self = self, !Task.isCancelled else { return }
                if self.isConnectedNow() { ticksSinceScan = 99; continue }

                ticksSinceScan += 1
                guard ticksSinceScan >= 2 else { continue }          // scan roughly every 2 s
                ticksSinceScan = 0

                let hosts = await Task.detached(priority: .utility) { HostDiscovery.discover(timeout: 1.2) }.value
                guard !Task.isCancelled, !self.isConnectedNow() else { continue }
                guard let h = hosts.first(where: { !$0.isUDP }) ?? hosts.first else { continue }

                DispatchQueue.main.async { self.hostName = h.name }
                if h.address == attempting { continue }              // already connecting to this PC
                attempting = h.address

                AppLog.log("discovered \(h.address):\(h.port) '\(h.name)' udp=\(h.isUDP)")
                UserDefaults.standard.set(h.address, forKey: "host")
                UserDefaults.standard.set(Int(h.port), forKey: "port")
                self.client.start(h.isUDP ? .udp(host: h.address, port: h.port)
                                          : .connectTCP(host: h.address, port: h.port))
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

// MARK: - Root view

struct ContentView: View {
    @StateObject private var model = StreamModel()
    @Environment(\.scenePhase) private var scenePhase

    // Remembered between launches (host/port are also written by automatic discovery).
    @AppStorage("manualMode") private var manualMode = false
    @AppStorage("proto") private var proto = "tcp"
    @AppStorage("host") private var host = ""
    @AppStorage("port") private var port = 5000
    @AppStorage("autoStart") private var autoStart = true
    @AppStorage("showStats") private var showStats = false

    @State private var showAdvanced = false
    @State private var didAutoStart = false

    private var choice: ConnectionChoice {
        manualMode ? (proto == "udp" ? .udp : .tcp) : .auto
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Always present (so the renderer is attached); covered by the home screen until a PC is connected.
            MetalVideoView(renderer: model.renderer) { id, phase, x, y, pressure in
                model.touch(id, phase, x, y, pressure)
            }
            .ignoresSafeArea()

            if model.running && model.connected {
                StreamingOverlay(showStats: showStats, fps: model.fps, rttMs: model.rttMs,
                                 onSettings: { showAdvanced = true },
                                 onDisconnect: { model.stop() })
                    .transition(.opacity)
            } else {
                HomeView(searching: model.running,
                         foundName: model.hostName,
                         onConnect: { startConnection() },
                         onCancel: { model.stop() },
                         onSettings: { showAdvanced = true })
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: model.connected)
        .animation(.easeInOut(duration: 0.4), value: model.running)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .sheet(isPresented: $showAdvanced) {
            AdvancedSettingsView(manualMode: $manualMode, proto: $proto, host: $host, port: $port,
                                 autoStart: $autoStart, showStats: $showStats,
                                 onReconnect: { startConnection() })
                .presentationDetents([.medium, .large])
        }
        .onAppear {
            // Zero-typing start: begin searching as soon as the app opens.
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
        model.stop()
        model.start(choice, host: host, port: UInt16(clamping: max(1, port)))
    }
}

// MARK: - Home screen (idle / searching)

struct HomeView: View {
    let searching: Bool
    let foundName: String
    var onConnect: () -> Void
    var onCancel: () -> Void
    var onSettings: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.03, green: 0.04, blue: 0.10),
                                    Color(red: 0.07, green: 0.10, blue: 0.24)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            // Portrait / tall layouts stack vertically; short landscape phones fall back to side-by-side.
            ViewThatFits(in: .vertical) {
                VStack(spacing: 22) {
                    emblem
                    VStack(spacing: 10) { heading; subtitle }
                    action
                }
                .padding(32)

                HStack(spacing: 40) {
                    emblem
                    VStack(alignment: .leading, spacing: 10) { heading; subtitle; action.padding(.top, 6) }
                }
                .padding(32)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button(action: onSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.75))
                    .padding(14)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .padding(18)
            .accessibilityLabel("Advanced settings")
        }
    }

    private var emblem: some View {
        ZStack {
            if searching { PulsingRings() }
            Image(systemName: "display")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(Color.white)
        }
        .frame(width: 170, height: 170)
    }

    private var heading: some View {
        Text("ScreenExt")
            .font(.system(size: 40, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.white)
    }

    @ViewBuilder private var subtitle: some View {
        if searching {
            VStack(spacing: 8) {
                Text(foundName.isEmpty ? "Searching for PC…" : "Connecting to \(foundName)…")
                    .font(.system(size: 19, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .modifier(SoftPulse())
                Text("Plug in via USB or ensure both devices are on the same Wi-Fi.")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }
        } else {
            Text("Use this screen as an extra display for your PC.")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
    }

    @ViewBuilder private var action: some View {
        if searching {
            Button("Cancel", action: onCancel)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.55))
        } else {
            Button(action: onConnect) {
                Text("Connect")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 54)
                    .padding(.vertical, 15)
                    .background(
                        Capsule().fill(LinearGradient(colors: [Color(red: 0.25, green: 0.55, blue: 1.0),
                                                               Color(red: 0.10, green: 0.35, blue: 0.95)],
                                                      startPoint: .top, endPoint: .bottom))
                    )
                    .shadow(color: Color.blue.opacity(0.45), radius: 16, y: 6)
            }
        }
    }
}

/// Soft expanding rings behind the display icon while searching.
struct PulsingRings: View {
    @State private var animate = false

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .stroke(Color.white.opacity(0.28), lineWidth: 1.5)
                    .scaleEffect(animate ? 1.0 : 0.45)
                    .opacity(animate ? 0 : 0.9)
                    .animation(.easeOut(duration: 2.4).repeatForever(autoreverses: false).delay(Double(i) * 0.8),
                               value: animate)
            }
        }
        .onAppear { animate = true }
    }
}

/// Gentle opacity breathing for the status line.
struct SoftPulse: ViewModifier {
    @State private var on = false

    func body(content: Content) -> some View {
        content
            .opacity(on ? 1.0 : 0.55)
            .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

// MARK: - Streaming overlay (small, unobtrusive)

struct StreamingOverlay: View {
    let showStats: Bool
    let fps: Int
    let rttMs: Double
    var onSettings: () -> Void
    var onDisconnect: () -> Void

    var body: some View {
        VStack {
            HStack(alignment: .top) {
                HStack(spacing: 6) {
                    Circle().fill(Color.green).frame(width: 7, height: 7)
                    Text(showStats ? "Connected · \(fps) fps · \(String(format: "%.0f", rttMs)) ms" : "Connected")
                        .font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(Color.white)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.black.opacity(0.45)))

                Spacer()

                HStack(spacing: 10) {
                    Button(action: onSettings) {
                        Image(systemName: "gearshape").font(.system(size: 16))
                    }
                    Button(action: onDisconnect) {
                        Image(systemName: "xmark").font(.system(size: 16, weight: .semibold))
                    }
                }
                .foregroundStyle(Color.white.opacity(0.85))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.black.opacity(0.45)))
            }
            .padding(12)
            Spacer()
        }
    }
}

// MARK: - Advanced settings (all the technical options live here)

struct AdvancedSettingsView: View {
    @Binding var manualMode: Bool
    @Binding var proto: String
    @Binding var host: String
    @Binding var port: Int
    @Binding var autoStart: Bool
    @Binding var showStats: Bool
    var onReconnect: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Connect automatically when the app opens", isOn: $autoStart)
                    Toggle("Show performance details", isOn: $showStats)
                }

                Section(header: Text("Connection"),
                        footer: Text("Automatic connection finds your PC over USB or Wi-Fi. Only enter an address if that doesn't work.")) {
                    Toggle("Enter PC address manually", isOn: $manualMode.animation())
                    if manualMode {
                        Picker("Protocol", selection: $proto) {
                            Text("TCP").tag("tcp")
                            Text("UDP").tag("udp")
                        }
                        .pickerStyle(.segmented)

                        TextField("PC address", text: $host)
                            .keyboardType(.numbersAndPunctuation)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)

                        TextField("Port", value: $port, format: .number)
                            .keyboardType(.numberPad)
                    }
                }

                Section(footer: Text("Diagnostics are saved to ScreenExt.log, visible in the Files app.")) {
                    Button("Reconnect now") {
                        onReconnect()
                        dismiss()
                    }
                }
            }
            .navigationTitle("Advanced")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
