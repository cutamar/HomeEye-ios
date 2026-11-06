/// Pure-Swift SHA-1 (FIPS 180-4). Used for WS-Security UsernameToken digests.
public enum SHA1 {
    /// Returns the 20-byte SHA-1 digest of `bytes`.
    public static func hash(_ bytes: [UInt8]) -> [UInt8] {
        var h0: UInt32 = 0x67452301
        var h1: UInt32 = 0xEFCDAB89
        var h2: UInt32 = 0x98BADCFE
        var h3: UInt32 = 0x10325476
        var h4: UInt32 = 0xC3D2E1F0

        for block in paddedBlocks(bytes) {
            var w = [UInt32](repeating: 0, count: 80)
            for i in 0..<16 {
                let o = i * 4
                w[i] = UInt32(block[o]) << 24
                    | UInt32(block[o + 1]) << 16
                    | UInt32(block[o + 2]) << 8
                    | UInt32(block[o + 3])
            }
            for i in 16..<80 {
                w[i] = rotateLeft(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], by: 1)
            }

            var a = h0
            var b = h1
            var c = h2
            var d = h3
            var e = h4

            for i in 0..<80 {
                var f: UInt32
                var k: UInt32
                switch i {
                case 0..<20:
                    f = (b & c) | (~b & d)
                    k = 0x5A827999
                case 20..<40:
                    f = b ^ c ^ d
                    k = 0x6ED9EBA1
                case 40..<60:
                    f = (b & c) | (b & d) | (c & d)
                    k = 0x8F1BBCDC
                default:
                    f = b ^ c ^ d
                    k = 0xCA62C1D6
                }
                let temp = rotateLeft(a, by: 5) &+ f &+ e &+ k &+ w[i]
                e = d
                d = c
                c = rotateLeft(b, by: 30)
                b = a
                a = temp
            }

            h0 = h0 &+ a
            h1 = h1 &+ b
            h2 = h2 &+ c
            h3 = h3 &+ d
            h4 = h4 &+ e
        }

        return [h0, h1, h2, h3, h4].flatMap(bigEndianBytes)
    }

    private static func paddedBlocks(_ bytes: [UInt8]) -> [[UInt8]] {
        var message = bytes
        let bitLength = UInt64(bytes.count) &* 8
        message.append(0x80)
        while message.count % 64 != 56 {
            message.append(0)
        }
        for i in (0..<8).reversed() {
            message.append(UInt8(truncatingIfNeeded: bitLength >> (8 * UInt64(i))))
        }
        return stride(from: 0, to: message.count, by: 64).map { Array(message[$0..<($0 + 64)]) }
    }

    private static func rotateLeft(_ x: UInt32, by n: UInt32) -> UInt32 {
        (x << n) | (x >> (32 - n))
    }

    private static func bigEndianBytes(_ word: UInt32) -> [UInt8] {
        (0..<4).reversed().map { UInt8(truncatingIfNeeded: word >> (8 * UInt32($0))) }
    }
}
