import XCTest
@testable import HomeEyeCore

final class CameraProbeTests: XCTestCase {
    private func fake(profiles: String, uris: [String: String], caps: String = Fixtures.caps) -> FakeTransport {
        let t = FakeTransport()
        t.on("GetSystemDateAndTime", xml: Fixtures.time)
        t.on("GetCapabilities", xml: caps)
        t.on("GetDeviceInformation", xml: Fixtures.deviceInfo)
        t.on("GetProfiles", xml: profiles)
        t.on("GetStreamUri") { req, _ in
            for (token, uri) in uris where req.body.contains("<trt:ProfileToken>\(token)</trt:ProfileToken>") {
                return FakeTransport.ok(Fixtures.uri(uri))
            }
            return Fixtures.status(500, "")
        }
        return t
    }

    private func probe(_ t: FakeTransport) async throws -> ProbeResult {
        try await CameraProbe.probe(host: "192.0.2.10", onvifPort: 2020, username: "u", password: "p", transport: t)
    }

    func testSortsBySizeAndFiltersJpeg() async throws {
        let t = fake(profiles: Fixtures.profiles([
            ("small", "minorStream", 640, 360, false),
            ("jpg", "jpegStream", 3840, 2160, false),
            ("big", "mainStream", 2304, 1296, true),
        ]), uris: [
            "big": "rtsp://192.0.2.10:554/stream1",
            "small": "rtsp://192.0.2.10:554/stream2",
            "jpg": "rtsp://192.0.2.10:554/mjpeg",
        ])
        let r = try await probe(t)
        XCTAssertEqual(r.mainPath, "/stream1")
        XCTAssertEqual(r.subPath, "/stream2")
        XCTAssertEqual(r.mainResolution, "2304\u{D7}1296")
        XCTAssertEqual(r.subResolution, "640\u{D7}360")
        XCTAssertEqual(r.info.model, "Tapo C200")
        XCTAssertTrue(r.hasPtz)
        XCTAssertFalse(t.requests.contains { $0.body.contains("<trt:ProfileToken>jpg</trt:ProfileToken>") })
    }

    func testOnlyJpegProfilesAreKept() async throws {
        let t = fake(profiles: Fixtures.profiles([("j", "JPEG", 640, 480, false)]),
                     uris: ["j": "rtsp://192.0.2.10/mjpeg"])
        let r = try await probe(t)
        XCTAssertEqual(r.mainPath, "/mjpeg")
        XCTAssertNil(r.subPath)
        XCTAssertNil(r.subResolution)
    }

    func testSingleProfileHasNoSub() async throws {
        let t = fake(profiles: Fixtures.profiles([("a", "main", 1920, 1080, true)]),
                     uris: ["a": "rtsp://192.0.2.10:554/stream1"])
        let r = try await probe(t)
        XCTAssertNil(r.subPath)
        XCTAssertNil(r.subResolution)
    }

    func testQueryKeptAndPortParsed() async throws {
        let t = fake(profiles: Fixtures.profiles([("a", "main", 1920, 1080, true)]),
                     uris: ["a": "rtsp://192.0.2.10:8554/live/ch0%201?a=1&amp;b=2"])
        let r = try await probe(t)
        XCTAssertEqual(r.rtspPort, 8554)
        XCTAssertEqual(r.mainPath, "/live/ch0%201?a=1&b=2")
    }

    func testDefaultPort() async throws {
        let t = fake(profiles: Fixtures.profiles([("a", "main", 1920, 1080, true)]),
                     uris: ["a": "rtsp://192.0.2.10/stream1"])
        let r = try await probe(t)
        XCTAssertEqual(r.rtspPort, 554)
    }

    func testNoPtzWithoutService() async throws {
        let t = fake(profiles: Fixtures.profiles([("a", "main", 1920, 1080, true)]),
                     uris: ["a": "rtsp://192.0.2.10/stream1"], caps: Fixtures.capsNoPtz)
        let r = try await probe(t)
        XCTAssertFalse(r.hasPtz)
    }

    func testNoProfilesFails() async {
        let t = fake(profiles: Fixtures.profiles([]), uris: [:])
        do {
            _ = try await probe(t)
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? OnvifError, OnvifError("Camera did not return a stream address"))
        }
    }

    func testCameraApplying() {
        let cam = Camera(name: "n", host: "h", model: "old")
        let info = DeviceInfo(manufacturer: "m", model: "Tapo C200", firmware: "f")
        let r = ProbeResult(info: info, rtspPort: 8554, mainPath: "/a", subPath: nil,
                            mainResolution: "1x1", subResolution: nil, hasPtz: false)
        let c = cam.applying(r)
        XCTAssertEqual(c.rtspPort, 8554)
        XCTAssertEqual(c.mainPath, "/a")
        XCTAssertNil(c.subPath)
        XCTAssertEqual(c.model, "Tapo C200")
        XCTAssertFalse(c.hasPtz)
        let blank = cam.applying(ProbeResult(info: DeviceInfo(manufacturer: "", model: "", firmware: ""), rtspPort: 554,
                                             mainPath: "/", subPath: nil, mainResolution: "", subResolution: nil, hasPtz: true))
        XCTAssertNil(blank.model)
    }

    func testOnvifPTZAdapter() async throws {
        let t = FakeTransport()
        t.on("GetSystemDateAndTime", xml: Fixtures.time)
        t.on("GetCapabilities", xml: Fixtures.caps)
        t.on("ContinuousMove", xml: "<a/>")
        t.on("Stop", xml: "<a/>")
        let client = OnvifClient(host: "192.0.2.10", username: "u", password: "p", transport: t)
        try await client.connect()
        let ptz = OnvifPTZ(client: client, profileToken: "tok")
        try await ptz.continuousMove(pan: 0.25, tilt: 0.5)
        try await ptz.stop()
        XCTAssertTrue(t.requests.contains { $0.op == "ContinuousMove" && $0.body.contains("x=\"0.25\" y=\"0.50\"") })
        XCTAssertEqual(t.requests.last?.op, "Stop")
    }
}
