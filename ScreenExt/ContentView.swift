// ContentView.swift
// Glue: StreamClient -> VideoDecoder -> VideoRenderer, plus touch back-channel and a tiny HUD.
//
// Requires iOS 16+ (persistentSystemOverlays). Keep your Xcode template's @main App struct:
//     @main struct ExtendApp: App { var body: some Scene { WindowGroup { ContentView() } } }

import SwiftUI
import UIKit

final class StreamModel: ObservableObject {
    @Published var status = "Idle"
    @Published var running = false
    @Published var fps = 0
    @Published var rttMs = 0.0
    @Published var decoderLog = ""

    let client = StreamClient()
    let decoder = VideoDecoder()
    let renderer = VideoRenderer()

    private let counterLock = NSLock()
    private var frameCount = 0
    private var timer: Timer?

    init() {
        client.onState = { [weak self] s in DispatchQueue.main.async { self?.status = s } }
        client.onRTT   = { [weak self] r in DispatchQueue.main.async { self?.rttMs = r } }

        // The host sends HELLO first on every new connection (before any video), so a decoder
        // reset here, on the network queue, is race-free with decode() calls on the same queue.
        client.onHello = { [weak self] info in
            self?.renderer.setStreamInfo(info)
            self?.decoder.reset()
        }
        client.onVideo = { [weak self] pkt in self?.decoder.decode(pkt) }

        decoder.onNeedKeyframe = { [weak self] in self?.client.sendKeyframeRequest() }
        decoder.onLog = { [weak self] s in
            print("[decoder] \(s)")
            DispatchQueue.main.async { self?.decoderLog = s }
        }
        decoder.onFrame = { [weak self] pb, _ in
            guard let self = self else { return }
            self.renderer.enqueue(pb)
            self.counterLock.lock(); self.frameCount += 1; self.counterLock.unlock()
        }

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.counterLock.lock(); let n = self.frameCount; self.frameCount = 0; self.counterLock.unlock()
            self.fps = n
        }
    }

    deinit { timer?.invalidate() }

    func start(_ mode: StreamMode) {
        Task { @MainActor in UIApplication.shared.isIdleTimerDisabled = true }   // don't dim/lock while streaming
        running = true
        client.start(mode)
    }

    func stop() {
        client.stop()
        running = false
        Task { @MainActor in UIApplication.shared.isIdleTimerDisabled = false }
    }
}

enum ConnectionChoice: String, CaseIterable, Identifiable {
    case listen  = "Listen (USB / PC connects)"
    case connect = "Connect to PC (TCP)"
    case udp     = "Connect to PC (UDP)"
    var id: String { rawValue }
}

struct ContentView: View {
    @StateObject private var model = StreamModel()
    @State private var choice: ConnectionChoice = .listen
    @State private var host = "192.168.1.10"
    @State private var port = "5000"

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            MetalVideoView(renderer: model.renderer) { id, phase, x, y, pressure in
                model.client.sendTouch(id: id, phase: phase, x: x, y: y, pressure: pressure)
            }
            .ignoresSafeArea()

            if model.running {
                VStack {
                    HStack(alignment: .top) {
                        Text("\(model.status) · \(model.fps) fps · RTT \(String(format: "%.1f", model.rttMs)) ms")
                            .font(.caption2.monospacedDigit())
                            .padding(6)
                            .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(Color.white)
                        Spacer()
                        Button { model.stop() } label: {
                            Image(systemName: "xmark.circle.fill").font(.title2)
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
    }

    private var settingsCard: some View {
        VStack(spacing: 12) {
            Text("PC Screen Extension").font(.headline)
            Picker("Mode", selection: $choice) {
                ForEach(ConnectionChoice.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)

            if choice != .listen {
                TextField("PC address", text: $host)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            TextField("Port", text: $port)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.numberPad)

            Button("Start") {
                let p = UInt16(port) ?? 5000
                switch choice {
                case .listen:  model.start(.listenTCP(port: p))
                case .connect: model.start(.connectTCP(host: host, port: p))
                case .udp:     model.start(.udp(host: host, port: p))
                }
            }
            .buttonStyle(.borderedProminent)

            Text(model.status).font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
