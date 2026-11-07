import XCTest
@testable import HomeEyeCore

final class G711Tests: XCTestCase {
    func testALawVectors() {
        XCTAssertEqual(G711.decode([0xD5, 0x55, 0xAA, 0x2A], codec: .pcma), [8, -8, 32256, -32256])
    }

    func testULawVectors() {
        XCTAssertEqual(G711.decode([0xFF, 0x7F, 0x80, 0x00], codec: .pcmu), [0, 0, 32124, -32124])
    }

    func testEmptyInputAndAllBytesDecode() {
        XCTAssertEqual(G711.decode([], codec: .pcma), [])
        let all = (0...255).map { UInt8($0) }
        XCTAssertEqual(G711.decode(all, codec: .pcma).count, 256)
        XCTAssertEqual(G711.decode(all, codec: .pcmu).count, 256)
    }
}
