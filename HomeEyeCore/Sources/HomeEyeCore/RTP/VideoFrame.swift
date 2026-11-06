public enum VideoCodec: String {
    case h264 = "H264"
    case h265 = "H265"
}

public struct VideoFrame: Equatable {
    public let codec: VideoCodec
    /// H.264: [SPS, PPS]; H.265: [VPS, SPS, PPS]. No start codes.
    public let parameterSets: [[UInt8]]
    /// NAL units excluding parameter sets and AUD.
    public let nalus: [[UInt8]]
    public let isKeyframe: Bool
    public let timestamp: UInt32

    public init(codec: VideoCodec, parameterSets: [[UInt8]], nalus: [[UInt8]], isKeyframe: Bool, timestamp: UInt32) {
        self.codec = codec
        self.parameterSets = parameterSets
        self.nalus = nalus
        self.isKeyframe = isKeyframe
        self.timestamp = timestamp
    }

    /// Each NAL prefixed with its 4-byte big-endian length.
    public func avcc() -> [UInt8] {
        var out: [UInt8] = []
        for nal in nalus {
            let n = UInt32(truncatingIfNeeded: nal.count)
            out.append(UInt8(truncatingIfNeeded: n >> 24))
            out.append(UInt8(truncatingIfNeeded: n >> 16))
            out.append(UInt8(truncatingIfNeeded: n >> 8))
            out.append(UInt8(truncatingIfNeeded: n))
            out.append(contentsOf: nal)
        }
        return out
    }
}

public protocol VideoDepacketizer: AnyObject {
    func push(_ packet: RTPPacket) -> [VideoFrame]
}
