// MetalVideoView.swift
// Renders decoded NV12 CVPixelBuffers through CVMetalTextureCache, cropped to the visible
// 2556x1179 area (the coded picture is 2556x1180 or 16-aligned), and captures multi-touch input.

import SwiftUI
import MetalKit
import CoreVideo

// MARK: - Geometry shared by rendering and touch mapping

/// Aspect-fit rectangle of the visible video inside `bounds`.
func fittedVideoRect(in bounds: CGRect, contentAspect: CGFloat) -> CGRect {
    guard bounds.width > 0, bounds.height > 0, contentAspect > 0 else { return bounds }
    let viewAspect = bounds.width / bounds.height
    if viewAspect > contentAspect {
        let w = bounds.height * contentAspect
        return CGRect(x: bounds.midX - w / 2, y: bounds.minY, width: w, height: bounds.height)
    } else {
        let h = bounds.width / contentAspect
        return CGRect(x: bounds.minX, y: bounds.midY - h / 2, width: bounds.width, height: h)
    }
}

// MARK: - Shader (compiled from source at runtime so no .metal file is required)

private let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Params { float2 uvScale; float2 uvOffset; float2 uvMax; };
struct VOut { float4 position [[position]]; float2 uv; };

vertex VOut videoVertex(uint vid [[vertex_id]], constant Params& p [[buffer(0)]]) {
    float2 pos[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    float2 uv[4]  = { float2(0, 1),   float2(1, 1),  float2(0, 0),  float2(1, 0) };
    VOut o;
    o.position = float4(pos[vid], 0, 1);
    o.uv = uv[vid] * p.uvScale + p.uvOffset;     // crop: only show the visible rectangle
    return o;
}

fragment float4 videoFragment(VOut in [[stage_in]],
                              constant Params& p [[buffer(0)]],
                              texture2d<float> yTex  [[texture(0)]],
                              texture2d<float> cbcrTex [[texture(1)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 uv = min(in.uv, p.uvMax);              // never sample the padding row/column
    float  y  = yTex.sample(s, uv).r;
    float2 c  = cbcrTex.sample(s, uv).rg;
    // BT.709, video (limited) range - matches the host's video processor output
    float Y  = (y * 255.0 - 16.0) / 219.0;
    float cb = (c.x * 255.0 - 128.0) / 224.0;
    float cr = (c.y * 255.0 - 128.0) / 224.0;
    float3 rgb = float3(Y + 1.5748 * cr,
                        Y - 0.1873 * cb - 0.4681 * cr,
                        Y + 1.8556 * cb);
    return float4(saturate(rgb), 1.0);
}
"""

private struct VideoParams {
    var uvScale: SIMD2<Float>
    var uvOffset: SIMD2<Float>
    var uvMax: SIMD2<Float>
}

// MARK: - Renderer

final class VideoRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?

    private let lock = NSLock()
    private var latest: CVPixelBuffer?        // only the newest frame is kept (drop-old = lowest latency)
    private var drawPending = false
    private var info = StreamInfo()
    private weak var view: MTKView?

    var contentAspect: CGFloat {
        lock.lock(); defer { lock.unlock() }
        return CGFloat(info.cropW) / CGFloat(max(1, info.cropH))
    }

    override init() {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else {
            fatalError("Metal is not available")
        }
        device = dev
        queue = q

        let lib: MTLLibrary
        do { lib = try dev.makeLibrary(source: shaderSource, options: nil) }
        catch { fatalError("Shader compile failed: \(error)") }

        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "videoVertex")
        d.fragmentFunction = lib.makeFunction(name: "videoFragment")
        d.colorAttachments[0].pixelFormat = .bgra8Unorm
        do { pipeline = try dev.makeRenderPipelineState(descriptor: d) }
        catch { fatalError("Pipeline creation failed: \(error)") }

        super.init()
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, dev, nil, &textureCache)
    }

    func attach(to view: MTKView) {
        self.view = view
        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.isPaused = true                    // we draw when a frame arrives, not on a timer
        view.enableSetNeedsDisplay = false
        view.delegate = self
    }

    func setStreamInfo(_ i: StreamInfo) {
        lock.lock(); info = i; lock.unlock()
    }

    /// Any thread. Keeps only the newest frame and schedules one draw on the main thread.
    func enqueue(_ pb: CVPixelBuffer) {
        lock.lock()
        latest = pb
        let schedule = !drawPending
        drawPending = true
        lock.unlock()
        if schedule {
            DispatchQueue.main.async { [weak self] in self?.view?.draw() }
        }
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        lock.lock()
        let pb = latest
        let i = info
        drawPending = false
        lock.unlock()

        guard let pb = pb, let cache = textureCache,
              let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              CVPixelBufferGetPlaneCount(pb) >= 2 else { return }

        let w0 = CVPixelBufferGetWidthOfPlane(pb, 0), h0 = CVPixelBufferGetHeightOfPlane(pb, 0)
        let w1 = CVPixelBufferGetWidthOfPlane(pb, 1), h1 = CVPixelBufferGetHeightOfPlane(pb, 1)

        var yRef: CVMetalTexture?, cRef: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pb, nil, .r8Unorm, w0, h0, 0, &yRef)
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pb, nil, .rg8Unorm, w1, h1, 1, &cRef)
        guard let yR = yRef, let cR = cRef,
              let yTex = CVMetalTextureGetTexture(yR), let cTex = CVMetalTextureGetTexture(cR),
              let cb = queue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }

        // Letterbox to the visible aspect ratio (a no-op on a 2556x1179 iPhone screen).
        let aspect = CGFloat(i.cropW) / CGFloat(max(1, i.cropH))
        let r = fittedVideoRect(in: CGRect(origin: .zero, size: view.drawableSize), contentAspect: aspect)
        enc.setViewport(MTLViewport(originX: Double(r.minX), originY: Double(r.minY),
                                    width: Double(r.width), height: Double(r.height), znear: 0, zfar: 1))

        // Texture coordinates are relative to the decoded buffer size (w0 x h0), which may be the
        // 2556x1180 coded size or a 16-aligned size; the crop rect is in the same pixel space.
        let tw = Float(w0), th = Float(h0)
        var params = VideoParams(
            uvScale:  SIMD2(Float(i.cropW) / tw, Float(i.cropH) / th),
            uvOffset: SIMD2(Float(i.cropX) / tw, Float(i.cropY) / th),
            uvMax:    SIMD2((Float(i.cropX + i.cropW) - 0.5) / tw, (Float(i.cropY + i.cropH) - 0.5) / th))

        enc.setRenderPipelineState(pipeline)
        enc.setVertexBytes(&params, length: MemoryLayout<VideoParams>.stride, index: 0)
        enc.setFragmentBytes(&params, length: MemoryLayout<VideoParams>.stride, index: 0)
        enc.setFragmentTexture(yTex, index: 0)
        enc.setFragmentTexture(cTex, index: 1)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()

        cb.present(drawable)
        // The CVMetalTextures must stay alive until the GPU has finished with them.
        cb.addCompletedHandler { _ in withExtendedLifetime((yR, cR, pb)) {} }
        cb.commit()
    }
}

// MARK: - Touch-capturing MTKView

final class TouchMTKView: MTKView {
    /// (pointerId, phase, x 0...1, y 0...1 inside the visible video area, pressure 0...1)
    var onTouch: ((UInt8, TouchPhase, Double, Double, Double) -> Void)?
    var contentAspect: () -> CGFloat = { 2556.0 / 1179.0 }

    private var ids: [ObjectIdentifier: UInt8] = [:]

    override init(frame: CGRect, device: MTLDevice?) {
        super.init(frame: frame, device: device)
        isMultipleTouchEnabled = true
        isOpaque = true
    }
    required init(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        draw()                                  // repaint after rotation/resizing (view is paused)
    }

    private func id(for t: UITouch, create: Bool) -> UInt8? {
        let key = ObjectIdentifier(t)
        if let v = ids[key] { return v }
        guard create else { return nil }
        let used = Set(ids.values)
        guard let free = (UInt8(0)..<UInt8(10)).first(where: { !used.contains($0) }) else { return nil }
        ids[key] = free
        return free
    }

    private func report(_ touches: Set<UITouch>, _ phase: TouchPhase) {
        let r = fittedVideoRect(in: bounds, contentAspect: contentAspect())
        guard r.width > 0, r.height > 0 else { return }
        for t in touches {
            guard let pid = id(for: t, create: phase == .down) else { continue }
            let p = t.location(in: self)
            let nx = min(1, max(0, Double((p.x - r.minX) / r.width)))
            let ny = min(1, max(0, Double((p.y - r.minY) / r.height)))
            let pressure = t.maximumPossibleForce > 0 ? Double(t.force / t.maximumPossibleForce) : 1.0
            onTouch?(pid, phase, nx, ny, min(1, max(0.01, pressure)))
            if phase == .up || phase == .cancel { ids.removeValue(forKey: ObjectIdentifier(t)) }
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?)     { report(touches, .down) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?)     { report(touches, .move) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?)     { report(touches, .up) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { report(touches, .cancel) }
}

// MARK: - SwiftUI wrapper

struct MetalVideoView: UIViewRepresentable {
    let renderer: VideoRenderer
    let onTouch: (UInt8, TouchPhase, Double, Double, Double) -> Void

    func makeUIView(context: Context) -> TouchMTKView {
        let v = TouchMTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        renderer.attach(to: v)
        v.contentAspect = { [weak renderer] in renderer?.contentAspect ?? 2556.0 / 1179.0 }
        v.onTouch = onTouch
        return v
    }

    func updateUIView(_ uiView: TouchMTKView, context: Context) {
        uiView.onTouch = onTouch
    }
}
