import XCTest
@testable import HomeEyeCore

final class HashTests: XCTestCase {
    private func repeatedA(_ count: Int) -> String {
        String(repeating: "a", count: count)
    }

    // MARK: MD5

    func testMD5EmptyString() {
        XCTAssertEqual(MD5.hex(""), "d41d8cd98f00b204e9800998ecf8427e")
    }

    func testMD5Abc() {
        XCTAssertEqual(MD5.hex("abc"), "900150983cd24fb0d6963f7d28e17f72")
    }

    func testMD5QuickBrownFox() {
        XCTAssertEqual(
            MD5.hex("The quick brown fox jumps over the lazy dog"),
            "9e107d9d372bb6826bd81d3542a419d6"
        )
    }

    func testMD5OneMillionA() {
        XCTAssertEqual(MD5.hex(repeatedA(1_000_000)), "7707d6ae4e027c70eea2a935c2296f21")
    }

    func testMD5PaddingBoundaries() {
        let expected: [Int: String] = [
            55: "ef1772b6dff9a122358552954ad0df65",
            56: "3b0c8ac703f828b04c6c197006d17218",
            63: "b06521f39153d618550606be297466d5",
            64: "014842d480b571495a4a0363793f7367",
            65: "c743a45e0d2e6a95cb859adae0248435",
        ]
        for (length, digest) in expected {
            XCTAssertEqual(MD5.hex(repeatedA(length)), digest, "length \(length)")
        }
    }

    func testMD5HashReturnsRawDigestBytes() {
        XCTAssertEqual(MD5.hash(Array("abc".utf8)).hexString, "900150983cd24fb0d6963f7d28e17f72")
        XCTAssertEqual(MD5.hash([]).count, 16)
    }

    // MARK: SHA-1

    func testSHA1EmptyInput() {
        XCTAssertEqual(SHA1.hash([]).hexString, "da39a3ee5e6b4b0d3255bfef95601890afd80709")
    }

    func testSHA1Abc() {
        XCTAssertEqual(
            SHA1.hash(Array("abc".utf8)).hexString,
            "a9993e364706816aba3e25717850c26c9cd0d89d"
        )
    }

    func testSHA1TwoBlockMessage() {
        let message = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
        XCTAssertEqual(
            SHA1.hash(Array(message.utf8)).hexString,
            "84983e441c3bd26ebaae4aa1f95129e5e54670f1"
        )
    }

    func testSHA1PaddingBoundaries() {
        let expected: [Int: String] = [
            55: "c1c8bbdc22796e28c0e15163d20899b65621d65a",
            56: "c2db330f6083854c99d4b5bfb6e8f29f201be699",
            63: "03f09f5b158a7a8cdad920bddc29b81c18a551f5",
            64: "0098ba824b5c16427bd7a1122a5a442a25ec644d",
            65: "11655326c708d70319be2610e8a57d9a5b959d3b",
        ]
        for (length, digest) in expected {
            XCTAssertEqual(SHA1.hash(Array(repeatedA(length).utf8)).hexString, digest, "length \(length)")
        }
    }

    // MARK: hexString

    func testHexStringIsLowercaseAndZeroPadded() {
        let bytes: [UInt8] = [0x00, 0x0f, 0xa0, 0xff]
        XCTAssertEqual(bytes.hexString, "000fa0ff")
        XCTAssertEqual([UInt8]().hexString, "")
    }
}
