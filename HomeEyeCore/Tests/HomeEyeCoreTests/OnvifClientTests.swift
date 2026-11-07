import XCTest
@testable import HomeEyeCore

struct RecordedRequest {
    let host: String
    let port: Int
    let path: String
    let body: String
    let headers: [(String, String)]
    var op: String { FakeTransport.operation(of: body) }
    func header(_ name: String) -> String? { headers.first { $0.0 == name }?.1 }
}

/// Routes by the SOAP body's operation element and records requests.
final class FakeTransport: SOAPTransport, @unchecked Sendable {
    typealias Handler = (RecordedRequest, Int) throws -> HTTPResponse
    private let lock = NSLock()
    private var handlers: [String: Handler] = [:]
    private var recorded: [RecordedRequest] = []
    private var counts: [String: Int] = [:]

    var requests: [RecordedRequest] { lock.withLock { recorded } }

    func on(_ op: String, _ h: @escaping Handler) { lock.withLock { handlers[op] = h } }
    func on(_ op: String, xml: String) { on(op) { _, _ in FakeTransport.ok(xml) } }

    static func ok(_ xml: String) -> HTTPResponse { HTTPResponse(status: 200, headers: Headers(), body: Array(xml.utf8)) }

    static func operation(of body: String) -> String {
        guard let r = body.range(of: "<s:Body><") else { return "" }
        let rest = body[r.upperBound...]
        let name = rest.prefix { $0 != ">" && $0 != "/" && $0 != " " }
        return String(name.split(separator: ":").last ?? "")
    }

    func post(host: String, port: Int, path: String, body: [UInt8], headers: [(String, String)],
              connectTimeout: TimeInterval, timeout: TimeInterval) throws -> HTTPResponse {
        let req = RecordedRequest(host: host, port: port, path: path, body: String(decoding: body, as: UTF8.self), headers: headers)
        let (h, n): (Handler?, Int) = lock.withLock {
            recorded.append(req)
            counts[req.op, default: 0] += 1
            return (handlers[req.op], counts[req.op]!)
        }
        guard let h else { return HTTPResponse(status: 500, headers: Headers(), body: []) }
        return try h(req, n)
    }
}

enum Fixtures {
    static let time = """
    <?xml version="1.0"?><s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:tds="http://www.onvif.org/ver10/device/wsdl" xmlns:tt="http://www.onvif.org/ver10/schema"><s:Body><tds:GetSystemDateAndTimeResponse><tds:SystemDateAndTime><tt:UTCDateTime><tt:Time><tt:Hour>9</tt:Hour><tt:Minute>49</tt:Minute><tt:Second>49</tt:Second></tt:Time><tt:Date><tt:Year>2026</tt:Year><tt:Month>10</tt:Month><tt:Day>31</tt:Day></tt:Date></tt:UTCDateTime><tt:LocalDateTime><tt:Time><tt:Hour>10</tt:Hour><tt:Minute>0</tt:Minute><tt:Second>0</tt:Second></tt:Time><tt:Date><tt:Year>2026</tt:Year><tt:Month>10</tt:Month><tt:Day>31</tt:Day></tt:Date></tt:LocalDateTime></tds:SystemDateAndTime></tds:GetSystemDateAndTimeResponse></s:Body></s:Envelope>
    """

    static let caps = """
    <?xml version="1.0"?><s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"><s:Body><tds:GetCapabilitiesResponse xmlns:tds="http://www.onvif.org/ver10/device/wsdl" xmlns:tt="http://www.onvif.org/ver10/schema"><tds:Capabilities><tt:Device><tt:XAddr>http://10.9.9.9:2020/onvif/device_service</tt:XAddr></tt:Device><tt:Media><tt:XAddr>http://10.9.9.9:2020/onvif/media_service</tt:XAddr></tt:Media><tt:PTZ><tt:XAddr>http://10.9.9.9:8080/onvif/ptz_service</tt:XAddr></tt:PTZ></tds:Capabilities></tds:GetCapabilitiesResponse></s:Body></s:Envelope>
    """

    static let capsNoPtz = """
    <?xml version="1.0"?><s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"><s:Body><tds:GetCapabilitiesResponse xmlns:tds="http://www.onvif.org/ver10/device/wsdl" xmlns:tt="http://www.onvif.org/ver10/schema"><tds:Capabilities><tt:Media><tt:XAddr>http://10.9.9.9:2020/onvif/media_service</tt:XAddr></tt:Media></tds:Capabilities></tds:GetCapabilitiesResponse></s:Body></s:Envelope>
    """

    static func profiles(_ items: [(token: String, name: String, w: Int, h: Int, ptz: Bool)]) -> String {
        let ps = items.map { i in
            "<trt:Profiles token=\"\(i.token)\" fixed=\"true\"><tt:Name>\(i.name)</tt:Name><tt:VideoEncoderConfiguration token=\"enc\"><tt:Name>enc</tt:Name><tt:Resolution><tt:Width>\(i.w)</tt:Width><tt:Height>\(i.h)</tt:Height></tt:Resolution></tt:VideoEncoderConfiguration>"
                + (i.ptz ? "<tt:PTZConfiguration token=\"ptz\"><tt:Name>ptz</tt:Name></tt:PTZConfiguration>" : "")
                + "</trt:Profiles>"
        }.joined()
        return "<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://www.w3.org/2003/05/soap-envelope\" xmlns:trt=\"http://www.onvif.org/ver10/media/wsdl\" xmlns:tt=\"http://www.onvif.org/ver10/schema\"><s:Body><trt:GetProfilesResponse>\(ps)</trt:GetProfilesResponse></s:Body></s:Envelope>"
    }

    static func uri(_ u: String) -> String {
        "<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://www.w3.org/2003/05/soap-envelope\" xmlns:trt=\"http://www.onvif.org/ver10/media/wsdl\" xmlns:tt=\"http://www.onvif.org/ver10/schema\"><s:Body><trt:GetStreamUriResponse><trt:MediaUri><tt:Uri>\(u)</tt:Uri></trt:MediaUri></trt:GetStreamUriResponse></s:Body></s:Envelope>"
    }

    static let deviceInfo = """
    <?xml version="1.0"?><s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:tds="http://www.onvif.org/ver10/device/wsdl"><s:Body><tds:GetDeviceInformationResponse><tds:Manufacturer>TP-Link</tds:Manufacturer><tds:Model>Tapo C200</tds:Model><tds:FirmwareVersion>1.3.0</tds:FirmwareVersion></tds:GetDeviceInformationResponse></s:Body></s:Envelope>
    """

    static func fault(reason: String?, subcode: String? = nil) -> String {
        "<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://www.w3.org/2003/05/soap-envelope\"><s:Body><s:Fault><s:Code><s:Value>s:Sender</s:Value>"
            + (subcode.map { "<s:Subcode><s:Value>\($0)</s:Value></s:Subcode>" } ?? "")
            + "</s:Code>" + (reason.map { "<s:Reason><s:Text xml:lang=\"en\">\($0)</s:Text></s:Reason>" } ?? "") + "</s:Fault></s:Body></s:Envelope>"
    }

    static func status(_ code: Int, _ body: String, headers: [(String, String)] = []) -> HTTPResponse {
        HTTPResponse(status: code, headers: Headers(fields: headers.map { (name: $0.0, value: $0.1) }), body: Array(body.utf8))
    }
}

final class OnvifClientTests: XCTestCase {
    private func client(_ t: FakeTransport, password: String = "p&ss") -> OnvifClient {
        OnvifClient(host: "192.0.2.10", port: 2020, username: "admin", password: password, transport: t)
    }

    private func connectedFake() -> FakeTransport {
        let t = FakeTransport()
        t.on("GetSystemDateAndTime", xml: Fixtures.time)
        t.on("GetCapabilities", xml: Fixtures.caps)
        return t
    }

    func testParsesCameraTime() {
        let d = OnvifClient.parseCameraTime(Fixtures.time)
        XCTAssertEqual(d, ISO8601DateFormatter().date(from: "2026-10-31T09:49:49Z"))
        func xml(_ y: Int, _ mo: Int, _ d: Int) -> String {
            "<a><UTCDateTime><Time><Hour>1</Hour><Minute>2</Minute><Second>3</Second></Time><Date><Year>\(y)</Year><Month>\(mo)</Month><Day>\(d)</Day></Date></UTCDateTime></a>"
        }
        XCTAssertNotNil(OnvifClient.parseCameraTime(xml(2026, 12, 31)))
        XCTAssertNil(OnvifClient.parseCameraTime(xml(0, 0, 0)))
        XCTAssertNil(OnvifClient.parseCameraTime(xml(2026, 13, 1)))
        XCTAssertNil(OnvifClient.parseCameraTime(xml(2026, 2, 32)))
        XCTAssertNil(OnvifClient.parseCameraTime("<a/>"))
        XCTAssertNil(OnvifClient.parseCameraTime("garbage <<"))
    }

    func testConnectRewritesHostAndSecurityHeaderOnlyAfterTime() async throws {
        let t = connectedFake()
        let c = client(t)
        XCTAssertFalse(c.isConnected)
        try await c.connect()
        XCTAssertTrue(c.isConnected)
        XCTAssertTrue(c.supportsPtz)
        let reqs = t.requests
        XCTAssertEqual(reqs.map(\.op), ["GetSystemDateAndTime", "GetCapabilities"])
        XCTAssertFalse(reqs[0].body.contains("Security"))
        XCTAssertTrue(reqs[1].body.contains("<wsse:Security"))
        XCTAssertEqual(reqs[0].path, "/onvif/device_service")
        XCTAssertEqual(reqs[0].header("Content-Type"), "application/soap+xml; charset=utf-8")

        t.on("GetProfiles", xml: Fixtures.profiles([("p1", "main", 1920, 1080, true)]))
        t.on("ContinuousMove", xml: "<a/>")
        _ = try await c.profiles()
        try await c.continuousMove(profileToken: "p1", pan: 0, tilt: 0)
        let after = t.requests.suffix(2)
        XCTAssertEqual(after.first?.path, "/onvif/media_service")
        XCTAssertEqual(after.first?.port, 2020)
        XCTAssertEqual(after.last?.path, "/onvif/ptz_service")
        XCTAssertEqual(after.last?.port, 8080)
        XCTAssertTrue(t.requests.allSatisfy { $0.host == "192.0.2.10" })
    }

    func testNoPtzCapability() async throws {
        let t = connectedFake()
        t.on("GetCapabilities", xml: Fixtures.capsNoPtz)
        let c = client(t)
        try await c.connect()
        XCTAssertFalse(c.supportsPtz)
        do {
            try await c.stop(profileToken: "p")
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? OnvifError, OnvifError("This camera doesn't support pan/tilt"))
        }
    }

    func testUnreachableTimeCallAborts() async {
        let t = FakeTransport()
        t.on("GetSystemDateAndTime") { _, _ in throw NetError.unreachable("no route") }
        t.on("GetCapabilities", xml: Fixtures.caps)
        let c = client(t)
        do {
            try await c.connect()
            XCTFail("expected error")
        } catch let e as OnvifError {
            XCTAssertEqual(e, OnvifError("Can't reach camera at 192.0.2.10:2020", unreachable: true))
        } catch { XCTFail("\(error)") }
        XCTAssertEqual(t.requests.map(\.op), ["GetSystemDateAndTime"])
    }

    func testNonUnreachableTimeFailureIsTolerated() async throws {
        let t = connectedFake()
        t.on("GetSystemDateAndTime") { _, _ in Fixtures.status(400, Fixtures.fault(reason: "Sender not Authorized")) }
        let c = client(t)
        try await c.connect()
        XCTAssertTrue(c.isConnected)
    }

    func testSecurityHeaderDigestRecomputes() async throws {
        let t = connectedFake()
        let c = client(t, password: "p&ss")
        try await c.connect()
        let body = try XCTUnwrap(t.requests.last?.body)
        func between(_ a: String, _ b: String) -> String {
            let s = body.range(of: a)!.upperBound
            return String(body[s...].prefix(upTo: body[s...].range(of: b)!.lowerBound))
        }
        let nonceB64 = between("Nonce EncodingType=\"http://docs.oasis-open.org/wss/2004/01/oasis-200401-soap-message-security-1.0#Base64Binary\">", "</wsse:Nonce>")
        let created = between("<wsu:Created>", "</wsu:Created>")
        let digestB64 = between("PasswordDigest\">", "</wsse:Password>")
        let nonce = try XCTUnwrap(Data(base64Encoded: nonceB64))
        XCTAssertEqual(nonce.count, 16)
        let expected = SHA1.hash(Array(nonce) + Array(created.utf8) + Array("p&ss".utf8))
        XCTAssertEqual(digestB64, Data(expected).base64EncodedString())
        XCTAssertTrue(body.contains("<wsse:Username>admin</wsse:Username>"))
        // Created uses the camera clock (2026-10-31 09:49:49Z at connect time) plus elapsed time.
        XCTAssertTrue(created.hasPrefix("2026-10-31T09:49:"), created)
        XCTAssertTrue(created.hasSuffix("Z"))
        XCTAssertFalse(body.contains("p&amp;ss"))
    }

    func testProfilesParsing() async throws {
        let t = connectedFake()
        t.on("GetProfiles", xml: Fixtures.profiles([
            ("profile_1", "mainStream", 2304, 1296, true),
            ("profile_2", "minorStream", 640, 360, false),
        ]))
        let c = client(t)
        try await c.connect()
        let p = try await c.profiles()
        XCTAssertEqual(p, [
            MediaProfile(token: "profile_1", name: "mainStream", width: 2304, height: 1296, hasPtz: true),
            MediaProfile(token: "profile_2", name: "minorStream", width: 640, height: 360, hasPtz: false),
        ])
    }

    func testDeviceInfoAndStreamUri() async throws {
        let t = connectedFake()
        t.on("GetDeviceInformation", xml: Fixtures.deviceInfo)
        t.on("GetStreamUri", xml: Fixtures.uri("rtsp://192.0.2.10:554/stream1"))
        let c = client(t)
        try await c.connect()
        let info = try await c.deviceInfo()
        XCTAssertEqual(info, DeviceInfo(manufacturer: "TP-Link", model: "Tapo C200", firmware: "1.3.0"))
        let uri = try await c.streamUri(profileToken: "profile_1")
        XCTAssertEqual(uri, "rtsp://192.0.2.10:554/stream1")
        XCTAssertTrue(t.requests.last!.body.contains("<trt:ProfileToken>profile_1</trt:ProfileToken>"))
    }

    func testStreamUriMissing() async throws {
        let t = connectedFake()
        t.on("GetStreamUri", xml: "<a><b/></a>")
        let c = client(t)
        try await c.connect()
        do {
            _ = try await c.streamUri(profileToken: "x")
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? OnvifError, OnvifError("Camera did not return a stream address"))
        }
    }

    func testFaultMapping() async throws {
        let t = connectedFake()
        let c = client(t)
        try await c.connect()
        func check(_ resp: HTTPResponse, _ message: String, file: StaticString = #filePath, line: UInt = #line) async {
            t.on("GetDeviceInformation") { _, _ in resp }
            do {
                _ = try await c.deviceInfo()
                XCTFail("expected error", file: file, line: line)
            } catch {
                XCTAssertEqual((error as? OnvifError)?.message, message, file: file, line: line)
                XCTAssertEqual((error as? OnvifError)?.unreachable, false, file: file, line: line)
            }
        }
        await check(Fixtures.status(401, ""), "Wrong username or password")
        await check(Fixtures.status(400, Fixtures.fault(reason: "Sender not Authorized", subcode: "ter:NotAuthorized")), "Wrong username or password")
        await check(Fixtures.status(500, Fixtures.fault(reason: "Authentication failed")), "Wrong username or password")
        await check(Fixtures.status(500, Fixtures.fault(reason: "Invalid args")), "Camera error: Invalid args")
        await check(Fixtures.status(503, "not xml <<"), "Camera error (HTTP 503)")
        await check(Fixtures.status(500, ""), "Camera error (HTTP 500)")
    }

    func testInvalidHostIsUnreachable() async {
        let t = connectedFake()
        let c = OnvifClient(host: "192.0.2.10\n ", port: 2020, username: "u", password: "p", transport: t)
        do {
            try await c.connect()
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? OnvifError, OnvifError("Can't reach camera at 192.0.2.10\n :2020", unreachable: true))
        }
        XCTAssertEqual(OnvifClient.map(.protocolError("invalid host"), host: "h", port: 1), OnvifError("Can't reach camera at h:1", unreachable: true))
        XCTAssertEqual(OnvifClient.map(.protocolError("bad status line"), host: "h", port: 1), OnvifError("Camera sent a reply we couldn't read"))
        XCTAssertTrue(t.requests.isEmpty)
    }

    func testTransportErrorMapping() {
        XCTAssertEqual(OnvifClient.map(.timeout, host: "h", port: 1), OnvifError("Camera at h:1 didn't answer in time", unreachable: true))
        XCTAssertEqual(OnvifClient.map(.closed, host: "h", port: 1), OnvifError("Can't reach camera at h:1", unreachable: true))
        XCTAssertEqual(OnvifClient.map(.io(5), host: "h", port: 1), OnvifError("Can't reach camera at h:1", unreachable: true))
        XCTAssertEqual(OnvifClient.map(.unreachable("x"), host: "h", port: 1), OnvifError("Can't reach camera at h:1", unreachable: true))
    }

    func testDigestRetryOn401() async throws {
        let t = connectedFake()
        t.on("GetDeviceInformation") { req, n in
            if n == 1 {
                XCTAssertNil(req.header("Authorization"))
                return Fixtures.status(401, "", headers: [("WWW-Authenticate", "Digest realm=\"r\", nonce=\"abc\", qop=\"auth\"")])
            }
            XCTAssertTrue(req.header("Authorization")?.hasPrefix("Digest ") == true)
            XCTAssertTrue(req.header("Authorization")?.contains("uri=\"/onvif/device_service\"") == true)
            return FakeTransport.ok(Fixtures.deviceInfo)
        }
        let c = client(t)
        try await c.connect()
        let info = try await c.deviceInfo()
        XCTAssertEqual(info.model, "Tapo C200")
        XCTAssertEqual(t.requests.filter { $0.op == "GetDeviceInformation" }.count, 2)
    }

    func testSecond401IsWrongPassword() async throws {
        let t = connectedFake()
        t.on("GetDeviceInformation") { _, _ in
            Fixtures.status(401, "", headers: [("WWW-Authenticate", "Digest realm=\"r\", nonce=\"abc\", qop=\"auth\"")])
        }
        let c = client(t)
        try await c.connect()
        do {
            _ = try await c.deviceInfo()
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? OnvifError, OnvifError("Wrong username or password"))
        }
        XCTAssertEqual(t.requests.filter { $0.op == "GetDeviceInformation" }.count, 2)
    }

    func testEscapingAndPanTiltFormatting() async throws {
        let t = connectedFake()
        t.on("ContinuousMove", xml: "<a/>")
        t.on("GotoPreset", xml: "<a/>")
        t.on("SetPreset", xml: "<a><PresetToken>7</PresetToken></a>")
        let c = client(t)
        try await c.connect()
        try await c.continuousMove(profileToken: "a&b<c", pan: 0.5, tilt: -1.7)
        var body = t.requests.last!.body
        XCTAssertTrue(body.contains("<tptz:ProfileToken>a&amp;b&lt;c</tptz:ProfileToken>"))
        XCTAssertTrue(body.contains("x=\"0.50\" y=\"-1.00\""), body)
        try await c.continuousMove(profileToken: "t", pan: 1.7, tilt: 0)
        body = t.requests.last!.body
        XCTAssertTrue(body.contains("x=\"1.00\" y=\"0.00\""), body)

        try await c.gotoPreset(profileToken: "a&", presetToken: "<1>")
        body = t.requests.last!.body
        XCTAssertTrue(body.contains("a&amp;") && body.contains("&lt;1&gt;"))
        let token = try await c.setPreset(profileToken: "t", name: "Door & <Gate>")
        XCTAssertEqual(token, "7")
        XCTAssertTrue(t.requests.last!.body.contains("<tptz:PresetName>Door &amp; &lt;Gate&gt;</tptz:PresetName>"))
    }

    func testPresets() async throws {
        let t = connectedFake()
        t.on("GetPresets", xml: "<a xmlns:tptz=\"x\"><tptz:Preset token=\"1\"><tt:Name>Door</tt:Name></tptz:Preset><tptz:Preset token=\"2\"><tt:Name>Gate</tt:Name></tptz:Preset></a>".replacingOccurrences(of: "<a ", with: "<a xmlns:tt=\"y\" "))
        let c = client(t)
        try await c.connect()
        let p = try await c.presets(profileToken: "t")
        XCTAssertEqual(p, [Preset(token: "1", name: "Door"), Preset(token: "2", name: "Gate")])
        XCTAssertEqual(p.first?.id, "1")
    }
}
