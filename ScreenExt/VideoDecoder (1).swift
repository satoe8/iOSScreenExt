// VideoDecoder.swift
// Annex-B H.264 access units -> AVCC samples -> VTDecompressionSession -> CVPixelBuffer (NV12).
//
// Low-latency decode notes:
//  * kVTVideoDecoderSpecification_EnableLowLatencyRateControl does NOT exist for decoders (it is a
//    kVTVideoEncoderSpecification_* key). What matters on the decode side:
//      - kVTDecompressionPropertyKey_RealTime = true (documented default, set explicitly)
//      - decode flags _EnableAsynchronousDecompression | _1xRealTimePlayback
//      - hardware decoder: implicit on iOS; on iOS 17+ we additionally *require* it so a failure is
//        loud instead of silently falling back to software (which could not keep up at 2556x1180@60)
//      - a stream with no frame reordering (our encoder emits no B-frames)
//  * Don't set kVTDecompressionPropertyKey_MaximizePowerEfficiency together with RealTime
//    (documented as unsupported).

import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

final class VideoDecoder {
    /// Decoded frame (NV12 CVPixelBuffer, Metal-compatible) and its host PTS in microseconds.
    var onFrame: ((CVPixelBuffer, UInt64) -> Void)?
    /// Called when the decoder needs an IDR (start of stream, loss, decode error).
    var onNeedKeyframe: (() -> Void)?
    var onLog: ((String) -> Void)?

    private(set) var decodedFrames = 0
    private(set) var droppedFrames = 0
    private(set) var errors = 0

    private var session: VTDecompressionSession?
    private var formatDesc: CMVideoFormatDescription?
    private var sps: Data?
    private var pps: Data?

    private let lock = NSLock()
    private var waitingForKey = true
    private var lastFrameNumber: UInt32?

    deinit { invalidate() }

    /// Forget everything (e.g. when reconnecting).
    func reset() {
        lock.lock(); waitingForKey = true; lastFrameNumber = nil; lock.unlock()
        invalidate()
        sps = nil; pps = nil; formatDesc = nil
    }

    // MARK: - Input

    /// Call from a single serial queue (the network queue).
    func decode(_ pkt: VideoPacket) {
        // 1. Continuity: a gap means the host dropped frames (or UDP lost one). Wait for an IDR.
        lock.lock()
        if let last = lastFrameNumber, pkt.frameNumber != last &+ 1 { waitingForKey = true }
        if pkt.isDiscontinuity { waitingForKey = true }
        lastFrameNumber = pkt.frameNumber
        let waiting = waitingForKey
        lock.unlock()

        // 2. Split Annex-B, collect parameter sets, build the AVCC payload.
        var newSPS: Data?, newPPS: Data?
        var avcc = Data()
        var hasIDR = false

        pkt.annexB.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: UInt8.self)
            for r in VideoDecoder.splitAnnexB(p) {
                let type = p[r.lowerBound] & 0x1F
                switch type {
                case 7: newSPS = Data(p[r])
                case 8: newPPS = Data(p[r])
                case 1, 5:
                    if type == 5 { hasIDR = true }
                    var len = UInt32(r.count).bigEndian
                    withUnsafeBytes(of: &len) { avcc.append(contentsOf: $0) }
                    avcc.append(p.baseAddress! + r.lowerBound, count: r.count)
                default: break          // AUD (9), SEI (6), ... are not needed for decoding
                }
            }
        }

        // 3. (Re)build the format description when SPS/PPS appear or change.
        if let s = newSPS, let pp = newPPS, (s != sps || pp != pps || formatDesc == nil || session == nil) {
            sps = s; pps = pp
            if !rebuildFormatAndSession() {
                requestKey(reason: "decoder setup failed")
                return
            }
        }

        // 4. Start only at an IDR.
        if waiting {
            if hasIDR {
                lock.lock(); waitingForKey = false; lock.unlock()
            } else {
                droppedFrames += 1
                requestKey(reason: nil)
                return
            }
        }
        guard let session = session, let fd = formatDesc, !avcc.isEmpty else { return }

        // 5. AVCC bytes -> CMBlockBuffer -> CMSampleBuffer
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: avcc.count, flags: 0, blockBufferOut: &block)
        guard status == noErr, let bb = block else { return }
        status = avcc.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: bb, offsetIntoDestination: 0, dataLength: avcc.count)
        }
        guard status == noErr else { return }

        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMTime(value: CMTimeValue(pkt.ptsUs), timescale: 1_000_000),
                                        decodeTimeStamp: .invalid)
        var size = avcc.count
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: bb, formatDescription: fd,
                                           sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                           sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard status == noErr, let sb = sample else { return }

        // 6. Decode (asynchronous, real-time). The handler runs on a VideoToolbox thread.
        var infoFlags = VTDecodeInfoFlags()
        status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sb,
            flags: [._EnableAsynchronousDecompression, ._1xRealTimePlayback],
            infoFlagsOut: &infoFlags
        ) { [weak self] st, _, imageBuffer, pts, _ in
            guard let self = self else { return }
            if st == noErr, let pb = imageBuffer {
                self.decodedFrames += 1
                let us = pts.isValid ? UInt64(max(0, pts.seconds * 1_000_000)) : 0
                self.onFrame?(pb, us)
            } else {
                self.errors += 1
                self.onLog?("decode callback error \(st)")
                self.markNeedKey()
            }
        }

        if status != noErr {
            errors += 1
            onLog?("VTDecompressionSessionDecodeFrame failed: \(status)")
            if status == kVTInvalidSessionErr {         // e.g. app was backgrounded
                _ = rebuildFormatAndSession()
            }
            markNeedKey()
        }
    }

    // MARK: - Session management

    private func invalidate() {
        if let s = session {
            VTDecompressionSessionWaitForAsynchronousFrames(s)
            VTDecompressionSessionInvalidate(s)
        }
        session = nil
    }

    private func rebuildFormatAndSession() -> Bool {
        guard let sps = sps, let pps = pps else { return false }
        invalidate()
        formatDesc = nil

        var fd: CMVideoFormatDescription?
        let st: OSStatus = sps.withUnsafeBytes { (spsRaw: UnsafeRawBufferPointer) -> OSStatus in
            pps.withUnsafeBytes { (ppsRaw: UnsafeRawBufferPointer) -> OSStatus in
                let ptrs: [UnsafePointer<UInt8>] = [spsRaw.bindMemory(to: UInt8.self).baseAddress!,
                                                    ppsRaw.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2,
                    parameterSetPointers: ptrs, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &fd)
            }
        }
        guard st == noErr, let desc = fd else { onLog?("format description failed: \(st)"); return false }
        formatDesc = desc
        let dims = CMVideoFormatDescriptionGetDimensions(desc)

        // These two keys only exist on iOS 17.0+ (the app deploys to iOS 16, so they must be guarded).
        var spec: [CFString: Any] = [:]
        if #available(iOS 17.0, *) {
            spec[kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder] = true
            spec[kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder] = true
        }
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
        ]

        var s: VTDecompressionSession?
        let cs = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: desc,
            decoderSpecification: spec as CFDictionary, imageBufferAttributes: attrs as CFDictionary,
            outputCallback: nil,                          // we use the per-frame output handler instead
            decompressionSessionOut: &s)
        guard cs == noErr, let session = s else {
            onLog?("VTDecompressionSessionCreate failed: \(cs) (decoder unavailable for \(dims.width)x\(dims.height)? On iOS 17+ this means no hardware decoder for this stream)")
            return false
        }
        VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        self.session = session
        onLog?("decoder ready \(dims.width)x\(dims.height), hardware, real-time")
        return true
    }

    // MARK: - Keyframe handling

    private func markNeedKey() {
        lock.lock(); waitingForKey = true; lock.unlock()
        requestKey(reason: nil)
    }

    private func requestKey(reason: String?) {
        if let r = reason { onLog?(r) }
        onNeedKeyframe?()      // StreamClient rate-limits these
    }

    // MARK: - Annex-B parsing

    /// Returns the byte ranges of each NAL unit (start codes and trailing zero bytes excluded).
    static func splitAnnexB(_ p: UnsafeBufferPointer<UInt8>) -> [Range<Int>] {
        let n = p.count
        var starts: [Int] = []          // index of the first byte AFTER each start code
        var i = 0
        while i + 3 <= n {
            if p[i] == 0 && p[i + 1] == 0 && p[i + 2] == 1 { starts.append(i + 3); i += 3 }
            else { i += 1 }
        }
        var out: [Range<Int>] = []
        for (k, s) in starts.enumerated() {
            var e = (k + 1 < starts.count) ? starts[k + 1] - 3 : n
            while e > s && p[e - 1] == 0 { e -= 1 }       // zero_byte / trailing_zero_8bits
            if e > s { out.append(s..<e) }
        }
        return out
    }
}
