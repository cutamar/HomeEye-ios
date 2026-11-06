public enum AudioCodec: String {
    case pcma = "PCMA"
    case pcmu = "PCMU"
}

/// ITU-T G.711 A-law / mu-law to 16-bit linear PCM.
public enum G711 {
    private static let alawTable: [Int16] = (0..<256).map { alaw(UInt8($0)) }
    private static let ulawTable: [Int16] = (0..<256).map { ulaw(UInt8($0)) }

    public static func decode(_ bytes: [UInt8], codec: AudioCodec) -> [Int16] {
        let table = codec == .pcma ? alawTable : ulawTable
        return bytes.map { table[Int($0)] }
    }

    private static func alaw(_ byte: UInt8) -> Int16 {
        let a = Int(byte ^ 0x55)
        let exponent = (a & 0x70) >> 4
        var t = (a & 0x0F) << 4
        switch exponent {
        case 0: t += 8
        case 1: t += 0x108
        default: t = (t + 0x108) << (exponent - 1)
        }
        return Int16(a & 0x80 != 0 ? t : -t)
    }

    private static func ulaw(_ byte: UInt8) -> Int16 {
        let u = Int(~byte)
        var t = (((u & 0x0F) << 3) + 0x84) << ((u & 0x70) >> 4)
        t -= 0x84
        return Int16(u & 0x80 != 0 ? -t : t)
    }
}
