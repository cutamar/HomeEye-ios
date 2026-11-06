public struct RTPPacket: Equatable {
    public let payloadType: UInt8
    public let marker: Bool
    public let sequence: UInt16
    public let timestamp: UInt32
    public let ssrc: UInt32
    public let payload: [UInt8]

    public init(payloadType: UInt8, marker: Bool, sequence: UInt16, timestamp: UInt32, ssrc: UInt32, payload: [UInt8]) {
        self.payloadType = payloadType
        self.marker = marker
        self.sequence = sequence
        self.timestamp = timestamp
        self.ssrc = ssrc
        self.payload = payload
    }

    /// Parses an RTP packet (RFC 3550). Returns nil for malformed input.
    public init?(_ bytes: [UInt8]) {
        guard bytes.count >= 12 else { return nil }
        let b0 = bytes[0]
        guard b0 >> 6 == 2 else { return nil }
        let hasPadding = b0 & 0x20 != 0
        let hasExtension = b0 & 0x10 != 0
        let csrcCount = Int(b0 & 0x0F)
        var offset = 12 + csrcCount * 4
        guard offset <= bytes.count else { return nil }
        if hasExtension {
            guard offset + 4 <= bytes.count else { return nil }
            let words = Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            offset += 4 + words * 4
            guard offset <= bytes.count else { return nil }
        }
        var end = bytes.count
        if hasPadding {
            let pad = Int(bytes[bytes.count - 1])
            guard pad >= 1, end - pad >= offset else { return nil }
            end -= pad
        }
        payloadType = bytes[1] & 0x7F
        marker = bytes[1] & 0x80 != 0
        sequence = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        timestamp = UInt32(bytes[4]) << 24 | UInt32(bytes[5]) << 16 | UInt32(bytes[6]) << 8 | UInt32(bytes[7])
        ssrc = UInt32(bytes[8]) << 24 | UInt32(bytes[9]) << 16 | UInt32(bytes[10]) << 8 | UInt32(bytes[11])
        payload = Array(bytes[offset..<end])
    }
}
