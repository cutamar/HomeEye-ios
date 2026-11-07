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

    func testUTF16DoctypeRejected() {
        let utf16 = Array("<?xml version=\"1.0\" encoding=\"UTF-16\"?><!DOCTYPE a [<!ENTITY x \"y\">]><a>&x;</a>".utf16)
        var le: [UInt8] = [0xFF, 0xFE]
        var be: [UInt8] = [0xFE, 0xFF]
        for u in utf16 {
            le += [UInt8(u & 0xFF), UInt8(u >> 8)]
            be += [UInt8(u >> 8), UInt8(u & 0xFF)]
        }
        XCTAssertThrowsError(try XML.parse(le))
        XCTAssertThrowsError(try XML.parse(be))
        XCTAssertThrowsError(try XML.parse(Array("<\0a\0>\0".utf8)))
    }

    func testCDATA() throws {
        let root = try XML.parse("<a><![CDATA[x<y]]>z</a>")
        XCTAssertEqual(root.text, "x<yz")
        XCTAssertEqual(root.textContent, "x<yz")
    }

    func testTruncatedAndMultiRootThrow() {
        XCTAssertThrowsError(try XML.parse("<a><b>"))
        XCTAssertThrowsError(try XML.parse("<a/><b/>"))
    }

    func testDepthLimit() throws {
        let deep = String(repeating: "<a>", count: 300) + String(repeating: "</a>", count: 300)
        XCTAssertThrowsError(try XML.parse(deep))
        let ok = String(repeating: "<a>", count: 100) + String(repeating: "</a>", count: 100)
        XCTAssertNoThrow(try XML.parse(ok))
    }

    func testFirstAndAllOnDeepWideDocumentAreFast() throws {
        var xml = String(repeating: "<a>", count: 250)
        for _ in 0..<2000 { xml += "<w><x>1</x></w>" }
        xml += String(repeating: "</a>", count: 250)
        let root = try XML.parse(xml)
        let start = Date()
        for _ in 0..<200 { XCTAssertEqual(root.text("x"), "1") }
        XCTAssertEqual(root.all("x").count, 2000)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }

    func testElementCountCap() {
        let ok = "<r>" + String(repeating: "<i/>", count: 49_000) + "</r>"
        XCTAssertNoThrow(try XML.parse(ok))
        let big = "<r>" + String(repeating: "<i/>", count: 50_001) + "</r>"
        XCTAssertThrowsError(try XML.parse(big)) { XCTAssertEqual($0 as? XMLError, .invalid) }
    }

    func testNonUTF8DeclaredEncodingRejected() throws {
        let utf7 = "<?xml version=\"1.0\" encoding=\"UTF-7\"?>+ADw-!DOCTYPE a [+ADw-!ENTITY x +ACI-y+ACI-]+AD4-+ADw-a+AD4-+ACY-x;+ADw-/a+AD4-"
        XCTAssertThrowsError(try XML.parse(utf7)) { XCTAssertEqual($0 as? XMLError, .invalid) }
        XCTAssertThrowsError(try XML.parse("<?xml version='1.0' encoding='EBCDIC-US'?><a/>"))
        XCTAssertThrowsError(try XML.parse("<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?><a/>"))
        XCTAssertNoThrow(try XML.parse("<?xml version=\"1.0\" encoding=\"utf-8\"?><a/>"))
        XCTAssertNoThrow(try XML.parse("<?xml version=\"1.0\" encoding=\"US-ASCII\"?><a/>"))
        XCTAssertNoThrow(try XML.parse("<?xml version=\"1.0\"?><a/>"))
    }
}
