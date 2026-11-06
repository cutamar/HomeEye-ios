@testable import HomeEyeCore

enum RTPBuilder {
    static func bytes(seq: UInt16, ts: UInt32, marker: Bool = false, pt: UInt8 = 96,
                      payload: [UInt8], csrc: Int = 0, extensionWords: Int? = nil, padding: Int = 0) -> [UInt8] {
        var b0: UInt8 = 0x80 | UInt8(csrc)
        if extensionWords != nil { b0 |= 0x10 }
        if padding > 0 { b0 |= 0x20 }
        var out: [UInt8] = [b0, (marker ? 0x80 : 0) | pt, UInt8(seq >> 8), UInt8(seq & 0xFF),
                            UInt8(ts >> 24), UInt8((ts >> 16) & 0xFF), UInt8((ts >> 8) & 0xFF), UInt8(ts & 0xFF),
                            0xDE, 0xAD, 0xBE, 0xEF]
        out += [UInt8](repeating: 0xCC, count: csrc * 4)
        if let w = extensionWords {
            out += [0xBE, 0xDE, UInt8(w >> 8), UInt8(w & 0xFF)]
            out += [UInt8](repeating: 0xEE, count: w * 4)
        }
        out += payload
        if padding > 0 {
            out += [UInt8](repeating: 0, count: padding - 1) + [UInt8(padding)]
        }
        return out
    }

    static func packet(seq: UInt16, ts: UInt32, marker: Bool = false, payload: [UInt8]) -> RTPPacket {
        RTPPacket(bytes(seq: seq, ts: ts, marker: marker, payload: payload))!
    }
}
