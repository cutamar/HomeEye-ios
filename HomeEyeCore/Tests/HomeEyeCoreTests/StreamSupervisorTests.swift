import XCTest
@testable import HomeEyeCore

final class StreamSupervisorTests: XCTestCase {
    let url = "rtsp://192.168.1.10:554/stream1"

    final class Recorder {
        private let lock = NSLock()
        private var _statuses: [StreamStatus] = []
        private var _connects = 0
        var statuses: [StreamStatus] { lock.lock(); defer { lock.unlock() }; return _statuses }
        var connects: Int { lock.lock(); defer { lock.unlock() }; return _connects }
        func add(_ s: StreamStatus) { lock.lock(); _statuses.append(s); lock.unlock() }
        func connected() -> Int { lock.lock(); defer { lock.unlock() }; _connects += 1; return _connects }
    }

    func liveStream() -> ScriptedStream {
        let sdp = "v=0\r\ns=x\r\na=control:*\r\nm=video 0 RTP/AVP 96\r\na=rtpmap:96 H264/90000\r\n"
            + "a=fmtp:96 sprop-parameter-sets=Z0IAH6o=,aM48gA==\r\na=control:track1\r\n"
        let frame = RTSPScript.interleaved(channel: 0, RTPBuilder.bytes(seq: 1, ts: 1, marker: true, payload: [0x65, 1, 2]))
        return ScriptedStream([
            .expect("OPTIONS", reply: RTSPScript.response(cseq: 1)),
            .expect("DESCRIBE", reply: RTSPScript.response(cseq: 2, body: sdp)),
            .expect("SETUP", reply: RTSPScript.response(cseq: 3, headers: [("Session", "S")])),
            .expect("PLAY", reply: RTSPScript.response(cseq: 4)),
            .send(frame + frame),
        ], holdOpen: true)
    }

    func testRetriesThenGoesLive() {
        let rec = Recorder()
        let stream = liveStream()
        let sup = StreamSupervisor(config: RTSPConfig(url: url), retryDelay: 0.2) { host, port, _ in
            XCTAssertEqual(host, "192.168.1.10")
            XCTAssertEqual(port, 554)
            if rec.connected() <= 2 { throw NetError.unreachable("no route") }
            return stream
        }
        let live = expectation(description: "live")
        sup.onStatus = { s in
            rec.add(s)
            if s == .live { live.fulfill() }
        }
        sup.start()
        sup.start()
        wait(for: [live], timeout: 5)
        sup.stop()
        XCTAssertTrue(sup.waitForExit(timeout: 1))
        XCTAssertEqual(rec.statuses, [.connecting, .retrying("Can't reach the camera"), .retrying("Can't reach the camera"), .live])
        XCTAssertEqual(rec.connects, 3)
        XCTAssertTrue(stream.isClosed)
    }

    func testStopDuringRetrySleepReturnsQuickly() {
        let rec = Recorder()
        let sup = StreamSupervisor(config: RTSPConfig(url: url), retryDelay: 30) { _, _, _ in
            _ = rec.connected()
            throw NetError.unreachable("no route")
        }
        let retrying = expectation(description: "retrying")
        sup.onStatus = { s in
            rec.add(s)
            if case .retrying = s { retrying.fulfill() }
        }
        sup.start()
        wait(for: [retrying], timeout: 2)
        let start = Date()
        sup.stop()
        XCTAssertTrue(sup.waitForExit(timeout: 0.5))
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
        XCTAssertEqual(rec.connects, 1)
        XCTAssertEqual(rec.statuses, [.connecting, .retrying("Can't reach the camera")])
    }

    func testStopWhileLiveClosesClientWithoutFurtherCallbacks() {
        let rec = Recorder()
        let stream = liveStream()
        let sup = StreamSupervisor(config: RTSPConfig(url: url), retryDelay: 0.2) { _, _, _ in
            _ = rec.connected()
            return stream
        }
        let live = expectation(description: "live")
        sup.onStatus = { s in
            rec.add(s)
            if s == .live { live.fulfill() }
        }
        sup.start()
        wait(for: [live], timeout: 3)
        sup.stop()
        XCTAssertTrue(sup.waitForExit(timeout: 1))
        XCTAssertTrue(stream.isClosed)
        XCTAssertEqual(rec.statuses, [.connecting, .live])
        XCTAssertEqual(rec.connects, 1)
    }

    func testFriendlyMessages() {
        XCTAssertEqual(StreamSupervisor.friendlyMessage(for: RTSPError.unauthorized), "Camera rejected the login")
        XCTAssertEqual(StreamSupervisor.friendlyMessage(for: NetError.unreachable("x")), "Can't reach the camera")
        XCTAssertEqual(StreamSupervisor.friendlyMessage(for: RTSPError.unsupportedCodec("JPEG")), "Unsupported video format (JPEG)")
        XCTAssertEqual(StreamSupervisor.friendlyMessage(for: NetError.timeout), "Connection lost")
        XCTAssertEqual(StreamSupervisor.friendlyMessage(for: RTSPError.badStatus(500, "x")), "Connection lost")
    }
}
