import XCTest
@testable import HomeEyeCore

/// Runs against a real camera. Skipped unless these are set:
///   HOMEEYE_CAM_HOST, HOMEEYE_CAM_USER, HOMEEYE_CAM_PASS  (and HOMEEYE_CAM_PORT, default 2020)
/// HOMEEYE_CAM_MOVE=1 also nudges the camera right and back.
/// Passwords are never printed.
final class LiveCameraTests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment

    private func requireHost() throws -> String {
        try XCTSkipUnless(env["HOMEEYE_CAM_HOST"] != nil, "HOMEEYE_CAM_HOST not set")
        return env["HOMEEYE_CAM_HOST"]!
    }

    private var port: Int { env["HOMEEYE_CAM_PORT"].flatMap { Int($0) } ?? 2020 }
    private var user: String { env["HOMEEYE_CAM_USER"] ?? "" }
    private var pass: String { env["HOMEEYE_CAM_PASS"] ?? "" }

    private func client(_ host: String, pass: String? = nil) -> OnvifClient {
        OnvifClient(host: host, port: port, username: user, password: pass ?? self.pass)
    }

    func testReadsCameraDetailsAndStreams() async throws {
        let host = try requireHost()
        let c = client(host)
        try await c.connect()
        let info = try await c.deviceInfo()
        print("Device: \(info)")
        let profiles = try await c.profiles()
        print("Profiles: \(profiles)")
        XCTAssertFalse(profiles.isEmpty)
        for p in profiles {
            let uri = try await c.streamUri(profileToken: p.token)
            // The URI may carry credentials; strip userinfo before logging.
            print("Stream \(p.name): \(Self.redacted(uri))")
        }
        print("PTZ: \(c.supportsPtz)")
    }

    func testWrongPasswordGivesClearError() async throws {
        let host = try requireHost()
        let c = client(host, pass: "definitely-wrong")
        do {
            try await c.connect()
            _ = try await c.profiles()
            XCTFail("expected an error")
        } catch {
            let message = (error as? OnvifError)?.message ?? "\(error)"
            print("Wrong password -> \(message)")
            XCTAssertEqual(message, "Wrong username or password")
        }
    }

    func testMovesAndStops() async throws {
        let host = try requireHost()
        try XCTSkipUnless(env["HOMEEYE_CAM_MOVE"] == "1", "HOMEEYE_CAM_MOVE not 1")
        let c = client(host)
        try await c.connect()
        let token = try await c.profiles()[0].token
        try await c.continuousMove(profileToken: token, pan: 0.5, tilt: 0)
        try await Task.sleep(nanoseconds: 500_000_000)
        try await c.stop(profileToken: token)
        try await Task.sleep(nanoseconds: 800_000_000)
        try await c.continuousMove(profileToken: token, pan: -0.5, tilt: 0)
        try await Task.sleep(nanoseconds: 500_000_000)
        try await c.stop(profileToken: token)
    }

    func testDiscoversCameras() throws {
        let host = try requireHost()
        guard let dot = host.lastIndex(of: ".") else {
            throw XCTSkip("HOMEEYE_CAM_HOST is not an IPv4 address")
        }
        // ".0" stands in for "our own address" so no real host is skipped
        let targets = Discovery.subnetHosts(String(host[..<dot]) + ".0")
        let found = Discovery.probe(timeout: 3, unicastTargets: targets)
        print("Discovered: \(found.map { "\($0.host):\($0.port)" })")
        XCTAssertTrue(found.contains { $0.host == host })
    }

    func testRtspDeliversKeyframeWithParameterSets() async throws {
        let host = try requireHost()
        let probe = try await CameraProbe.probe(host: host, onvifPort: port, username: user, password: pass)
        let path = probe.mainPath.hasPrefix("/") ? probe.mainPath : "/" + probe.mainPath
        let config = RTSPConfig(url: "rtsp://\(host):\(probe.rtspPort)\(path)",
                                credentials: Credentials(username: user, password: pass),
                                wantAudio: false)
        let supervisor = StreamSupervisor(config: config)
        let got = expectation(description: "keyframe with parameter sets")
        got.assertForOverFulfill = false
        supervisor.onVideo = { frame in
            if frame.isKeyframe, !frame.parameterSets.isEmpty, frame.parameterSets.allSatisfy({ !$0.isEmpty }) {
                got.fulfill()
            }
        }
        supervisor.start()
        await fulfillment(of: [got], timeout: 10)
        supervisor.stop()
    }

    private static func redacted(_ uri: String) -> String {
        guard let at = uri.firstIndex(of: "@"), let scheme = uri.range(of: "://") else { return uri }
        return String(uri[..<scheme.upperBound]) + "***@" + String(uri[uri.index(after: at)...])
    }
}

final class UnreachableTests: XCTestCase {
    func testUnreachableCameraFailsFastWithClearMessage() async {
        // 192.0.2.x is reserved for documentation; nothing ever answers there.
        let start = Date()
        let c = OnvifClient(host: "192.0.2.1", port: 2020, username: "u", password: "p", connectTimeout: 1.5)
        do {
            try await c.connect()
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual((error as? OnvifError)?.unreachable, true, "\(error)")
        }
        let took = Date().timeIntervalSince(start)
        XCTAssertLessThan(took, 2.5)
    }
}
