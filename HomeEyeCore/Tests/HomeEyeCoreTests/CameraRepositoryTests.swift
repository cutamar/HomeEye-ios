import XCTest
@testable import HomeEyeCore

final class CameraRepositoryTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("homeeye-test-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    func testRoundTrip() throws {
        let c = Camera(id: "a", name: "Porch", host: "192.168.1.5", onvifPort: 8000, rtspPort: 8554,
                       username: "u", mainPath: "/m", subPath: nil, model: "C200",
                       hasPtz: false, invertPan: true, invertTilt: true)
        let data = try JSONEncoder().encode(c)
        XCTAssertEqual(try JSONDecoder().decode(Camera.self, from: data), c)
    }

    func testDecodeDefaults() throws {
        let json = #"{"id":"x","name":"N","host":"h"}"#.data(using: .utf8)!
        let c = try JSONDecoder().decode(Camera.self, from: json)
        XCTAssertEqual(c.onvifPort, 2020)
        XCTAssertEqual(c.rtspPort, 554)
        XCTAssertEqual(c.username, "")
        XCTAssertEqual(c.mainPath, "/stream1")
        XCTAssertEqual(c.subPath, "/stream2")
        XCTAssertNil(c.model)
        XCTAssertTrue(c.hasPtz)
        XCTAssertFalse(c.invertPan)
        XCTAssertFalse(c.invertTilt)
    }

    func testUnknownKeysIgnored() throws {
        let json = #"{"id":"x","name":"N","host":"h","future":{"a":1},"z":[1]}"#.data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(Camera.self, from: json).id, "x")
    }

    func testMissingRequiredFails() {
        let json = #"{"id":"x","name":"N"}"#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(Camera.self, from: json))
    }

    func testUpsertReplacesAndAppends() throws {
        let repo = CameraRepository(directory: dir, secrets: InMemorySecretStore())
        XCTAssertFalse(repo.hadSavedFile)
        try repo.upsert(Camera(id: "a", name: "One", host: "h1"), password: "p1")
        try repo.upsert(Camera(id: "b", name: "Two", host: "h2"), password: "p2")
        try repo.upsert(Camera(id: "a", name: "One2", host: "h1"), password: "p3")
        XCTAssertEqual(repo.cameras.map(\.name), ["One2", "Two"])
        XCTAssertEqual(repo.password(for: "a"), "p3")
        XCTAssertEqual(repo.password(for: "zzz"), "")

        let reloaded = CameraRepository(directory: dir, secrets: InMemorySecretStore())
        XCTAssertTrue(reloaded.hadSavedFile)
        XCTAssertEqual(reloaded.cameras.map(\.name), ["One2", "Two"])
        XCTAssertEqual(reloaded.camera(id: "b")?.host, "h2")
    }

    func testDeleteRemovesSecretAndThumbnail() throws {
        let secrets = InMemorySecretStore()
        let repo = CameraRepository(directory: dir, secrets: secrets)
        try repo.upsert(Camera(id: "a", name: "One", host: "h"), password: "p")
        let thumb = repo.thumbnailURL(for: "a")
        XCTAssertEqual(thumb, dir.appendingPathComponent("thumbs").appendingPathComponent("a.jpg"))
        try FileManager.default.createDirectory(at: thumb.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: thumb)
        repo.delete(id: "a")
        XCTAssertTrue(repo.cameras.isEmpty)
        XCTAssertNil(secrets.password(for: "a"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: thumb.path))
        XCTAssertTrue(CameraRepository(directory: dir, secrets: secrets).cameras.isEmpty)
    }

    func testPasswordNeverInJSON() throws {
        let repo = CameraRepository(directory: dir, secrets: InMemorySecretStore())
        try repo.upsert(Camera(id: "a", name: "One", host: "h", username: "admin"), password: "s3cretPW")
        let text = try String(contentsOf: dir.appendingPathComponent("cameras.json"), encoding: .utf8)
        XCTAssertFalse(text.contains("s3cretPW"))
        XCTAssertTrue(text.contains("admin"))
    }

    func testCorruptFileLoadsEmpty() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json{".utf8).write(to: dir.appendingPathComponent("cameras.json"))
        let repo = CameraRepository(directory: dir, secrets: InMemorySecretStore())
        XCTAssertTrue(repo.cameras.isEmpty)
    }

    func testRtspURL() {
        var c = Camera(id: "a", name: "n", host: "10.0.0.2")
        XCTAssertEqual(c.rtspURL(hd: true), "rtsp://10.0.0.2:554/stream1")
        XCTAssertEqual(c.rtspURL(hd: false), "rtsp://10.0.0.2:554/stream2")
        c.subPath = nil
        XCTAssertEqual(c.rtspURL(hd: false), "rtsp://10.0.0.2:554/stream1")
        c.host = "fe80::1"
        c.mainPath = "live"
        XCTAssertEqual(c.rtspURL(hd: true), "rtsp://[fe80::1]:554/live")
    }
}
