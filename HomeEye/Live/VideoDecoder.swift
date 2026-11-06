import AVFoundation
import CoreImage
import CoreMedia
import HomeEyeCore
import UIKit
import VideoToolbox

/// Decodes H.264/H.265 `VideoFrame`s with VideoToolbox and shows them on an `AVSampleBufferDisplayLayer`.
///
/// `decode(_:)` is called on the RTSP thread. `onSize` is always called on the main queue.
final class VideoDecoder {
    /// Called on the main queue when the decoded picture size changes. Set it on the main queue.
    var onSize: ((CGSize) -> Void)?

    private let layer: AVSampleBufferDisplayLayer

    // Decode state. Guarded by `stateLock`, which is held for the whole of `decode`/`reset`.
    // Lock order: stateLock -> outputLock. The output handler only takes outputLock.
    private let stateLock = NSLock()
    private var session: VTDecompressionSession?
    private var formatDescription: CMFormatDescription?
    private var codec: VideoCodec?
    private var parameterSets: [[UInt8]] = []
    private var waitingForKeyframe = true

    // Output state. Guarded by `outputLock`.
    private let outputLock = NSLock()
    private var latest: CVPixelBuffer?
    private var lastSize: CGSize = .zero
    private var sessionFailed = false

    private static let ciContext = CIContext()

    // VTErrors.h values, spelled out so the comparison is OSStatus-to-OSStatus.
    private static let invalidSessionErr: OSStatus = -12903 // kVTInvalidSessionErr
    private static let badDataErr: OSStatus = -12909 // kVTVideoDecoderBadDataErr
    private static let malfunctionErr: OSStatus = -12911 // kVTVideoDecoderMalfunctionErr

    init(layer: AVSampleBufferDisplayLayer) {
        self.layer = layer
    }

    deinit {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
    }

    func decode(_ frame: VideoFrame) {
        stateLock.lock()
        defer { stateLock.unlock() }

        outputLock.lock()
        let failed = sessionFailed
        sessionFailed = false
        outputLock.unlock()
        if failed {
            invalidateLocked()
        }

        if session == nil || frame.codec != codec || frame.parameterSets != parameterSets {
            invalidateLocked()
            guard frame.isKeyframe else { return }
            guard createSessionLocked(for: frame) else { return }
        }

        if waitingForKeyframe {
            guard frame.isKeyframe else { return }
            waitingForKeyframe = false
        }

        guard let session, let formatDescription else { return }
        guard let sampleBuffer = makeSampleBuffer(frame, formatDescription: formatDescription) else { return }

        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [._1xRealTimePlayback],
            infoFlagsOut: nil
        ) { [weak self] status, _, imageBuffer, _, _ in
            self?.handleOutput(status: status, imageBuffer: imageBuffer)
        }
        if Self.isFatal(status) {
            invalidateLocked()
        }
    }

    func latestImage() -> UIImage? {
        outputLock.lock()
        let buffer = latest
        outputLock.unlock()
        guard let buffer else { return nil }
        let ci = CIImage(cvPixelBuffer: buffer)
        guard let cg = Self.ciContext.createCGImage(ci, from: ci.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    func reset() {
        stateLock.lock()
        invalidateLocked()
        stateLock.unlock()

        outputLock.lock()
        latest = nil
        lastSize = .zero
        sessionFailed = false
        outputLock.unlock()

        let layer = self.layer
        DispatchQueue.main.async {
            layer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        }
    }

    // MARK: - Session

    /// Requires `stateLock`.
    private func invalidateLocked() {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        formatDescription = nil
        codec = nil
        parameterSets = []
        waitingForKeyframe = true
    }

    /// Requires `stateLock`. Returns false if the format description or session could not be created.
    private func createSessionLocked(for frame: VideoFrame) -> Bool {
        guard let fd = Self.makeFormatDescription(codec: frame.codec, parameterSets: frame.parameterSets) else {
            return false
        }
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        var newSession: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: nil,
            formatDescription: fd,
            decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &newSession
        )
        guard status == noErr, let newSession else { return false }
        session = newSession
        formatDescription = fd
        codec = frame.codec
        parameterSets = frame.parameterSets
        waitingForKeyframe = true
        return true
    }

    private static func makeFormatDescription(codec: VideoCodec, parameterSets: [[UInt8]]) -> CMFormatDescription? {
        let required = codec == .h264 ? 2 : 3
        guard parameterSets.count >= required, parameterSets.allSatisfy({ !$0.isEmpty }) else { return nil }

        // One contiguous buffer so every pointer comes from a single withUnsafeBufferPointer scope.
        var flat: [UInt8] = []
        var offsets: [Int] = []
        var sizes: [Int] = []
        for ps in parameterSets {
            offsets.append(flat.count)
            sizes.append(ps.count)
            flat.append(contentsOf: ps)
        }

        var fd: CMFormatDescription?
        let status: OSStatus = flat.withUnsafeBufferPointer { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return -1 }
            let pointers: [UnsafePointer<UInt8>] = offsets.map { base + $0 }
            switch codec {
            case .h264:
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: pointers.count,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &fd
                )
            case .h265:
                return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: pointers.count,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    extensions: nil,
                    formatDescriptionOut: &fd
                )
            }
        }
        guard status == noErr else { return nil }
        return fd
    }

    private func makeSampleBuffer(_ frame: VideoFrame, formatDescription: CMFormatDescription) -> CMSampleBuffer? {
        let data = frame.avcc()
        let n = data.count
        guard n > 0 else { return nil }

        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: n,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: n,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let blockBuffer else { return nil }

        status = data.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: n
            )
        }
        guard status == noErr else { return nil }

        var sampleBuffer: CMSampleBuffer?
        let sampleSizes: [Int] = [n]
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: sampleSizes,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr else { return nil }
        return sampleBuffer
    }

    // MARK: - Output

    private static func isFatal(_ status: OSStatus) -> Bool {
        status == invalidSessionErr || status == badDataErr || status == malfunctionErr
    }

    /// Runs on a VideoToolbox thread, possibly inside `VTDecompressionSessionDecodeFrame` (stateLock held),
    /// so it must never take `stateLock`.
    private func handleOutput(status: OSStatus, imageBuffer: CVImageBuffer?) {
        if Self.isFatal(status) {
            // The next decode() invalidates the session and waits for a keyframe.
            outputLock.lock()
            sessionFailed = true
            outputLock.unlock()
            return
        }
        guard status == noErr, let imageBuffer else { return }

        let size = CGSize(width: CVPixelBufferGetWidth(imageBuffer), height: CVPixelBufferGetHeight(imageBuffer))
        outputLock.lock()
        latest = imageBuffer
        let sizeChanged = size != lastSize
        lastSize = size
        outputLock.unlock()

        if sizeChanged {
            DispatchQueue.main.async { [weak self] in
                self?.onSize?(size)
            }
        }

        var formatDescription: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: imageBuffer,
            formatDescriptionOut: &formatDescription
        ) == noErr, let formatDescription else { return }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: imageBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return }

        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true)!
        let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(
            dict,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        )

        let renderer = layer.sampleBufferRenderer
        if renderer.status == .failed {
            renderer.flush()
        }
        renderer.enqueue(sampleBuffer)
    }
}
