import XCTest
@testable import HomeEyeCore

final class SmokeTests: XCTestCase {
    func testVersionIsNotEmpty() {
        XCTAssertFalse(HomeEyeCoreInfo.version.isEmpty)
    }
}
