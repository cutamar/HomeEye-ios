import XCTest
@testable import HomeEyeCore

final class SDPTests: XCTestCase {
    private let tapo = [
        "v=0",
        "o=- 14665860 31787219 1 IN IP4 192.168.1.20",
        "s=Session streamed by \"TP-LINK RTSP Server\"",
        "t=0 0",
        "a=control:*",
        "m=video 0 RTP/AVP 96",
        "a=rtpmap:96 H264/90000",
        "a=fmtp:96 packetization-mode=1; profile-level-id=640032; sprop-parameter-sets=Z2QAMqwsaoHgCJ+WEAAAAwAQAAADAyjxgxUg,aO4xshs=",
        "a=control:track1",
        "m=audio 0 RTP/AVP 8",
        "a=rtpmap:8 PCMA/8000",
        "a=control:track2",
        "",
    ].joined(separator: "\r\n")

    func testTapoSDP() {
        let sd = SessionDescription.parse(tapo)
        XCTAssertEqual(sd.sessionControl, "*")
        XCTAssertEqual(sd.media.count, 2)
        let v = sd.video
        XCTAssertEqual(v?.type, "video")
        XCTAssertEqual(v?.payloadType, 96)
        XCTAssertEqual(v?.encoding, "H264")
        XCTAssertEqual(v?.clockRate, 90000)
        XCTAssertEqual(v?.control, "track1")
        XCTAssertEqual(v?.fmtp["packetization-mode"], "1")
        XCTAssertEqual(v?.fmtp["profile-level-id"], "640032")
        let sets = v?.parameterSets ?? []
        XCTAssertEqual(sets.count, 2)
        XCTAssertEqual(sets.first?.first, 0x67)
        XCTAssertEqual(sets.last, [0x68, 0xEE, 0x31, 0xB2, 0x1B])
        let a = sd.audio
        XCTAssertEqual(a?.encoding, "PCMA")
        XCTAssertEqual(a?.clockRate, 8000)
        XCTAssertEqual(a?.channels, 1)
        XCTAssertEqual(a?.control, "track2")
    }

    func testStaticPCMUWithoutRtpmap() {
        let sd = SessionDescription.parse("m=audio 0 RTP/AVP 0\na=control:a\n")
        XCTAssertEqual(sd.audio?.encoding, "PCMU")
        XCTAssertEqual(sd.audio?.clockRate, 8000)
        XCTAssertNil(sd.sessionControl)
    }

    func testH265() {
        let sdp = """
        v=0
        m=video 0 RTP/AVP 98
        a=rtpmap:98 h265/90000
        a=fmtp:98 sprop-vps=QAEMAf//AWAAAAMAgAAAAwAAAwB4lcwJ; SPROP-SPS=QgEBAWAAAAMAgAAAAwAAAwB4oAPAgBDlljKkkyvAQEBAIA==; sprop-pps=RAHA8vA8kA==
        a=control:rtsp://10.0.0.1/stream1/track1
        """
        let v = SessionDescription.parse(sdp).video
        XCTAssertEqual(v?.encoding, "H265")
        let sets = v?.parameterSets ?? []
        XCTAssertEqual(sets.count, 3)
        XCTAssertEqual(sets[0].first, 0x40)
        XCTAssertEqual(sets[1].first, 0x42)
        XCTAssertEqual(sets[2].first, 0x44)
    }

    func testMalformedLinesIgnored() {
        let sdp = "garbage\nm=video\nm=video x RTP/AVP y\na=rtpmap:abc\n=\nm=video 0 RTP/AVP 96\na=rtpmap:96 H264/90000\na=fmtp:96 noequals; =x; sprop-parameter-sets=!!!,Zw==\na=rtpmap:\n"
        let sd = SessionDescription.parse(sdp)
        XCTAssertEqual(sd.video?.payloadType, 96)
        XCTAssertEqual(sd.video?.parameterSets, [[0x67]])
        XCTAssertEqual(SessionDescription.parse("").media.count, 0)
    }

    func testResolveControl() {
        XCTAssertEqual(resolveControl(base: "rtsp://h/s", control: nil), "rtsp://h/s")
        XCTAssertEqual(resolveControl(base: "rtsp://h/s", control: "*"), "rtsp://h/s")
        XCTAssertEqual(resolveControl(base: "rtsp://h/s", control: "rtsps://x/y"), "rtsps://x/y")
        XCTAssertEqual(resolveControl(base: "rtsp://h/s", control: "track1"), "rtsp://h/s/track1")
        XCTAssertEqual(resolveControl(base: "rtsp://h/s/", control: "track1"), "rtsp://h/s/track1")
    }
}
