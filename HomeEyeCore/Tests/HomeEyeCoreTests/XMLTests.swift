import XCTest
@testable import HomeEyeCore

final class XMLTests: XCTestCase {
    func testEscapesUserText() {
        XCTAssertEqual(XML.escape("a&b<c>"), "a&amp;b&lt;c&gt;")
        XCTAssertEqual(XML.escape("\"'"), "&quot;&apos;")
    }

    func testNestedPrefixedLookup() throws {
        let xml = """
        <?xml version="1.0"?>
        <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:tds="http://www.onvif.org/ver10/device/wsdl">
          <s:Body><tds:GetSystemDateAndTimeResponse><tds:SystemDateAndTime>
            <tt:UTCDateTime xmlns:tt="http://www.onvif.org/ver10/schema">
              <tt:Time><tt:Hour>10</tt:Hour><tt:Minute>5</tt:Minute></tt:Time>
            </tt:UTCDateTime>
          </tds:SystemDateAndTime></tds:GetSystemDateAndTimeResponse></s:Body>
        </s:Envelope>
        """
        let root = try XML.parse(xml)
        XCTAssertEqual(root.name, "Envelope")
        XCTAssertNil(root.attribute("s"))
        XCTAssertTrue(root.attributes.isEmpty)
        let utc = try XCTUnwrap(root.first("UTCDateTime"))
        XCTAssertEqual(utc.text("Hour"), "10")
        XCTAssertEqual(utc.first("Time")?.children("Minute").count, 1)
        XCTAssertEqual(root.all("Hour").count, 1)
        XCTAssertEqual(root.all("Envelope").count, 0)
    }

    func testAttributeToken() throws {
        let xml = """
        <env><trt:GetProfilesResponse xmlns:trt="x">
        <trt:Profiles token="profile_1" fixed="true"><tt:Name xmlns:tt="y">mainStream</tt:Name></trt:Profiles>
        <trt:Profiles token="profile_2"><tt:Name xmlns:tt="y">minorStream</tt:Name></trt:Profiles>
        </trt:GetProfilesResponse></env>
        """
        let profiles = try XML.parse(xml).all("Profiles")
        XCTAssertEqual(profiles.map { $0.attribute("token") }, ["profile_1", "profile_2"])
        XCTAssertEqual(profiles[0].text("Name"), "mainStream")
        XCTAssertNil(profiles[0].attribute("xmlns:trt"))
    }

    func testTextContentAcrossChildren() throws {
        let root = try XML.parse("<a>x<b>y<c>z</c></b>w</a>")
        XCTAssertEqual(root.textContent, "xyzw")
        XCTAssertEqual(root.text, "xw")
        XCTAssertEqual(try XML.parse("<a><b>  \n hi \n</b></a>").text("b"), "hi")
    }

    func testDoctypeRejected() {
        let evil = "<?xml version=\"1.0\"?><!DOCTYPE a [<!ENTITY x \"y\">]><a>&x;</a>"
        XCTAssertThrowsError(try XML.parse(evil)) { XCTAssertEqual($0 as? XMLError, .doctypeNotAllowed) }
        XCTAssertThrowsError(try XML.parse("<!doctype a><a/>")) { XCTAssertEqual($0 as? XMLError, .doctypeNotAllowed) }
        XCTAssertThrowsError(try XML.parse(Array("<!entity x><a/>".utf8)))
    }

    func testGarbageAndEmptyThrow() {
        XCTAssertThrowsError(try XML.parse("not xml at all"))
        XCTAssertThrowsError(try XML.parse("<a><b></a>"))
        XCTAssertThrowsError(try XML.parse(""))
        XCTAssertThrowsError(try XML.parse([UInt8]()))
        XCTAssertThrowsError(try XML.parse([0xFF, 0xFE, 0x00]))
    }
}
