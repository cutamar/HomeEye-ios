import XCTest
@testable import HomeEyeCore

final class RTSPClientTests: XCTestCase {
    let url = "rtsp://192.168.1.10:554/stream1"
    let base = "rtsp://192.168.1.10:554/stream1/"
    let creds = Credentials(username: "admin", password: "s3cret")
    let sps: [UInt8] = [0x67, 0x42, 0x00, 0x1F, 0xAA]
    let pps: [UInt8] = [0x68, 0xCE, 0x3C, 0x80]
    let idr: [UInt8] = [0x65, 1, 2, 3, 4]
    let slice: [UInt8] = [0x41, 9, 8, 7]

    func sdp(sessionControl: String = "*", videoControl: String = "track1", audio: Bool = true,
             audioRtpmap: String = "8 PCMA/8000") -> String {
        var s = "v=0\r\no=- 1 1 IN IP4 192.168.1.10\r\ns=Session\r\nt=0 0\r\na=control:\(sessionControl)\r\n"
        s += "m=video 0 RTP/AVP 96\r\na=rtpmap:96 H264/90000\r\n"
        s += "a=fmtp:96 packetization-mode=1;sprop-parameter-sets=Z0IAH6o=,aM48gA==\r\n"
        s += "a=control:\(videoControl)\r\n"
        if audio {
            s += "m=audio 0 RTP/AVP 8\r\na=rtpmap:\(audioRtpmap)\r\na=control:track2\r\n"
        }
        return s
    }

    func video(_ seq: UInt16, _ ts: UInt32, _ payload: [UInt8]) -> [UInt8] {
        RTSPScript.interleaved(channel: 0, RTPBuilder.bytes(seq: seq, ts: ts, marker: true, payload: payload))
    }

    final class Box: @unchecked Sendable {
        var error: Error?
    }

    struct Collected {
        var infos: [StreamInfo] = []
        var frames: [VideoFrame] = []
        var audio: [AudioPacket] = []
    }

    /// Runs the client to completion; returns what it delivered and the error it threw.
    func runClient(_ config: RTSPConfig, _ stream: ScriptedStream) -> (Collected, Error?) {
        var c = Collected()
        let client = RTSPClient(config: config, stream: stream)
        do {
            try client.run(onInfo: { c.infos.append($0) }, onVideo: { c.frames.append($0) },
                           onAudio: { c.audio.append($0) })
            return (c, nil)
        } catch {
            return (c, error)
        }
    }

    static func digestParam(_ header: String, _ key: String) -> String? {
        guard header.hasPrefix("Digest ") else { return nil }
        return AuthChallenge.parseParams(String(header.dropFirst(7)))[key]
    }

    func assertDigest(_ r: ScriptedRequest, realm: String = "cam", nonce: String = "abc123",
                      file: StaticString = #filePath, line: UInt = #line) {
        guard let auth = r.headers["Authorization"] else {
            return XCTFail("\(r.method) missing Authorization", file: file, line: line)
        }
        XCTAssertEqual(Self.digestParam(auth, "uri"), r.uri, "\(r.method) uri", file: file, line: line)
        let ha1 = MD5.hex("admin:\(realm):s3cret")
        let ha2 = MD5.hex("\(r.method):\(r.uri)")
        XCTAssertEqual(Self.digestParam(auth, "response"), MD5.hex("\(ha1):\(nonce):\(ha2)"),
                       "\(r.method) response", file: file, line: line)
        XCTAssertFalse(auth.contains("s3cret"), file: file, line: line)
    }

    // MARK: - Handshake

    func testFullDigestHandshakeThenFrames() {
        let challenge = ("WWW-Authenticate", "Digest realm=\"cam\", nonce=\"abc123\"")
        let rtcp = RTSPScript.interleaved(channel: 1, [0x80, 0xC8, 0, 6] + [UInt8](repeating: 0, count: 24))
        let stream = ScriptedStream([
            .expect("OPTIONS", reply: RTSPScript.response(cseq: 1, headers: [("Public", "OPTIONS, DESCRIBE, SETUP, PLAY, GET_PARAMETER, TEARDOWN")]), check: { r in
                XCTAssertEqual(r.uri, self.url)
                XCTAssertEqual(r.headers["CSeq"], "1")
                XCTAssertEqual(r.headers["User-Agent"], "HomeEye")
                XCTAssertNil(r.headers["Authorization"])
            }),
            .expect("DESCRIBE", reply: RTSPScript.response(401, "Unauthorized", cseq: 2, headers: [challenge]), check: { r in
                XCTAssertEqual(r.headers["Accept"], "application/sdp")
                XCTAssertNil(r.headers["Authorization"])
            }),
            .expect("DESCRIBE", reply: RTSPScript.response(cseq: 3, headers: [("Content-Base", base), ("Content-Type", "application/sdp")], body: sdp()), check: { r in
                XCTAssertEqual(r.headers["CSeq"], "3")
                XCTAssertEqual(r.uri, self.url)
                self.assertDigest(r)
            }),
            .expect("SETUP", reply: RTSPScript.response(cseq: 4, headers: [("Session", "ABC123;timeout=60"), ("Transport", "RTP/AVP/TCP;unicast;interleaved=0-1")]), check: { r in
                XCTAssertEqual(r.uri, self.base + "track1")
                XCTAssertEqual(r.headers["Transport"], "RTP/AVP/TCP;unicast;interleaved=0-1")
                XCTAssertNil(r.headers["Session"])
                self.assertDigest(r)
            }),
            .expect("SETUP", reply: RTSPScript.response(cseq: 5, headers: [("Session", "ABC123;timeout=60"), ("Transport", "RTP/AVP/TCP;unicast;interleaved=2-3")]), check: { r in
                XCTAssertEqual(r.uri, self.base + "track2")
                XCTAssertEqual(r.headers["Transport"], "RTP/AVP/TCP;unicast;interleaved=2-3")
                XCTAssertEqual(r.headers["Session"], "ABC123")
                self.assertDigest(r)
            }),
            .expect("PLAY", reply: RTSPScript.response(cseq: 6, headers: [("Session", "ABC123")]), check: { r in
                XCTAssertEqual(r.uri, self.base)
                XCTAssertEqual(r.headers["Session"], "ABC123")
                XCTAssertEqual(r.headers["Range"], "npt=0.000-")
                self.assertDigest(r)
            }),
            .send(video(1, 1000, idr) + rtcp + video(2, 4000, slice)),
        ])
        let (c, err) = runClient(RTSPConfig(url: url, credentials: creds), stream)
        XCTAssertEqual(err as? NetError, .closed)
        XCTAssertEqual(stream.requests.map(\.method), ["OPTIONS", "DESCRIBE", "DESCRIBE", "SETUP", "SETUP", "PLAY"])
        XCTAssertTrue(stream.unexpected.isEmpty, "\(stream.unexpected.map(\.method))")
        XCTAssertEqual(c.infos, [StreamInfo(videoCodec: .h264, audio: .pcma, audioSampleRate: 8000, authScheme: .digest)])
        XCTAssertEqual(c.frames, [
            VideoFrame(codec: .h264, parameterSets: [sps, pps], nalus: [idr], isKeyframe: true, timestamp: 1000),
            VideoFrame(codec: .h264, parameterSets: [sps, pps], nalus: [slice], isKeyframe: false, timestamp: 4000),
        ])
    }

    func testBasicAuthWithoutContentBase() {
        let expected = "Basic " + Data("admin:s3cret".utf8).base64EncodedString()
        let stream = ScriptedStream([
            .expect("OPTIONS", reply: RTSPScript.response(cseq: 1)),
            .expect("DESCRIBE", reply: RTSPScript.response(401, "Unauthorized", cseq: 2, headers: [("WWW-Authenticate", "Basic realm=\"cam\"")])),
            .expect("DESCRIBE", reply: RTSPScript.response(cseq: 3, body: sdp(sessionControl: "*", videoControl: "trackID=1", audio: true)), check: { r in
                XCTAssertEqual(r.headers["Authorization"], expected)
            }),
            .expect("SETUP", reply: RTSPScript.response(cseq: 4, headers: [("Session", "77")]), check: { r in
                XCTAssertEqual(r.uri, self.url + "/trackID=1")
                XCTAssertEqual(r.headers["Authorization"], expected)
            }),
            .expect("PLAY", reply: RTSPScript.response(cseq: 5), check: { r in
                // No Content-Base: aggregate control uses the URL as given.
                XCTAssertEqual(r.uri, self.url)
                XCTAssertEqual(r.headers["Session"], "77")
                XCTAssertEqual(r.headers["Authorization"], expected)
            }),
        ])
        let (c, err) = runClient(RTSPConfig(url: url, credentials: creds, wantAudio: false), stream)
        XCTAssertEqual(err as? NetError, .closed)
        XCTAssertEqual(stream.requests.map(\.method), ["OPTIONS", "DESCRIBE", "DESCRIBE", "SETUP", "PLAY"])
        XCTAssertEqual(c.infos, [StreamInfo(videoCodec: .h264, audio: nil, audioSampleRate: 0, authScheme: .basic)])
    }

    func testRefuseBasicNeverSendsBasicCredentials() {
        let basic = ("WWW-Authenticate", "Basic realm=\"cam\"")
        let stream = ScriptedStream([
            .expect("OPTIONS", reply: RTSPScript.response(401, "Unauthorized", cseq: 1, headers: [basic])),
            .expect("DESCRIBE", reply: RTSPScript.response(401, "Unauthorized", cseq: 2, headers: [basic])),
            .expect("DESCRIBE", reply: RTSPScript.response(cseq: 3, body: sdp())),
        ], holdOpen: true)
        let (_, err) = runClient(RTSPConfig(url: url, credentials: creds, refuseBasic: true), stream)
        XCTAssertEqual(err as? RTSPError, .unauthorized)
        XCTAssertEqual(stream.requests.map(\.method), ["OPTIONS", "DESCRIBE"])
        XCTAssertTrue(stream.requests.allSatisfy { $0.headers["Authorization"] == nil })
        XCTAssertTrue(stream.unexpected.isEmpty)
    }

    func testRefuseBasicStillAcceptsDigest() {
        let both = [("WWW-Authenticate", "Basic realm=\"cam\""), ("WWW-Authenticate", "Digest realm=\"cam\", nonce=\"abc123\"")]
        let stream = ScriptedStream([
            .expect("OPTIONS", reply: RTSPScript.response(cseq: 1)),
            .expect("DESCRIBE", reply: RTSPScript.response(401, "Unauthorized", cseq: 2, headers: both)),
            .expect("DESCRIBE", reply: RTSPScript.response(cseq: 3, body: sdp(audio: false)), check: { r in
                self.assertDigest(r)
            }),
            .expect("SETUP", reply: RTSPScript.response(cseq: 4, headers: [("Session", "S")])),
            .expect("PLAY", reply: RTSPScript.response(cseq: 5)),
        ])
        let (c, err) = runClient(RTSPConfig(url: url, credentials: creds, refuseBasic: true), stream)
        XCTAssertEqual(err as? NetError, .closed)
        XCTAssertEqual(c.infos.map(\.authScheme), [.digest])
    }

    func testNoAuthReportsNone() {
        let stream = ScriptedStream([
            .expect("OPTIONS", reply: RTSPScript.response(cseq: 1)),
            .expect("DESCRIBE", reply: RTSPScript.response(cseq: 2, body: sdp(audio: false))),
            .expect("SETUP", reply: RTSPScript.response(cseq: 3, headers: [("Session", "S")])),
            .expect("PLAY", reply: RTSPScript.response(cseq: 4)),
        ])
        let (c, _) = runClient(RTSPConfig(url: url, credentials: creds), stream)
        XCTAssertEqual(c.infos.map(\.authScheme), [AuthScheme.none])
        XCTAssertTrue(stream.requests.allSatisfy { $0.headers["Authorization"] == nil })
    }

    func testOptions401IsToleratedByAuthenticating() {
        let challenge = ("WWW-Authenticate", "Digest realm=\"cam\", nonce=\"abc123\"")
        let stream = ScriptedStream([
            .expect("OPTIONS", reply: RTSPScript.response(401, "Unauthorized", cseq: 1, headers: [challenge])),
            .expect("DESCRIBE", reply: RTSPScript.response(cseq: 2, body: sdp(audio: false)), check: { r in
                self.assertDigest(r)
            }),
            .expect("SETUP", reply: RTSPScript.response(cseq: 3, headers: [("Session", "S")])),
            .expect("PLAY", reply: RTSPScript.response(cseq: 4)),
        ])
        let (_, err) = runClient(RTSPConfig(url: url, credentials: creds), stream)
        XCTAssertEqual(err as? NetError, .closed)
        XCTAssertEqual(stream.requests.map(\.method), ["OPTIONS", "DESCRIBE", "SETUP", "PLAY"])
    }

    func testUnauthorizedTwice() {
        let challenge = ("WWW-Authenticate", "Digest realm=\"cam\", nonce=\"abc123\"")
        let stream = ScriptedStream([
            .expect("OPTIONS", reply: RTSPScript.response(cseq: 1)),
            .expect("DESCRIBE", reply: RTSPScript.response(401, "Unauthorized", cseq: 2, headers: [challenge])),
            .expect("DESCRIBE", reply: RTSPScript.response(401, "Unauthorized", cseq: 3, headers: [challenge])),
        ], holdOpen: true)
        let (_, err) = runClient(RTSPConfig(url: url, credentials: creds), stream)
        XCTAssertEqual(err as? RTSPError, .unauthorized)
        XCTAssertEqual(stream.requests.count, 3)
    }

    func testUnauthorizedWithoutCredentials() {
        let stream = ScriptedStream([
            .expect("OPTIONS", reply: RTSPScript.response(cseq: 1)),
            .expect("DESCRIBE", reply: RTSPScript.response(401, "Unauthorized", cseq: 2, headers: [("WWW-Authenticate", "Basic realm=\"x\"")])),
        ], holdOpen: true)
        let (_, err) = runClient(RTSPConfig(url: url, credentials: nil), stream)
        XCTAssertEqual(err as? RTSPError, .unauthorized)
    }

    func testBadStatus() {
        let stream = ScriptedStream([
            .expect("OPTIONS", reply: RTSPScript.response(cseq: 1)),
            .expect("DESCRIBE", reply: RTSPScript.response(404, "Not Found", cseq: 2)),
        ], holdOpen: true)
        let (_, err) = runClient(RTSPConfig(url: url), stream)
        XCTAssertEqual(err as? RTSPError, .badStatus(404, "Not Found"))
    }

    func testMJPEGOnlyIsUnsupported() {
        let mjpeg = "v=0\r\ns=x\r\nm=video 0 RTP/AVP 26\r\na=rtpmap:26 JPEG/90000\r\na=control:track1\r\n"
        let stream = ScriptedStream([
            .expect("OPTIONS", reply: RTSPScript.response(cseq: 1)),
            .expect("DESCRIBE", reply: RTSPScript.response(cseq: 2, body: mjpeg)),
        ], holdOpen: true)
        let (_, err) = runClient(RTSPConfig(url: url), stream)
        XCTAssertEqual(err as? RTSPError, .unsupportedCodec("JPEG"))
    }

    func testAudioOnlyIsNoVideoTrack() {
        let audioOnly = "v=0\r\ns=x\r\nm=audio 0 RTP/AVP 0\r\na=control:track2\r\n"
        let stream = ScriptedStream([
            .expect("OPTIONS", reply: RTSPScript.response(cseq: 1)),
            .expect("DESCRIBE", reply: RTSPScript.response(cseq: 2, body: audioOnly)),
        ], holdOpen: true)
        let (_, err) = runClient(RTSPConfig(url: url), stream)
        XCTAssertEqual(err as? RTSPError, .noVideoTrack)
    }

    // MARK: - Host pinning

    /// Runs a Digest handshake with the given Content-Base / video control and returns the requests.
    func runHostile(contentBase: String?, videoControl: String, sessionControl: String = "*") -> ([ScriptedRequest], Error?) {
        let challenge = ("WWW-Authenticate", "Digest realm=\"cam\", nonce=\"abc123\"")
        var headers: [(String, String)] = []
        if let cb = contentBase { headers.append(("Content-Base", cb)) }
        let stream = ScriptedStream([
            .expect("OPTIONS", reply: RTSPScript.response(cseq: 1)),
            .expect("DESCRIBE", reply: RTSPScript.response(401, "Unauthorized", cseq: 2, headers: [challenge])),
            .expect("DESCRIBE", reply: RTSPScript.response(cseq: 3, headers: headers,
                                                          body: sdp(sessionControl: sessionControl, videoControl: videoControl, audio: false))),
            .expect("SETUP", reply: RTSPScript.response(cseq: 4, headers: [("Session", "S")])),
            .expect("PLAY", reply: RTSPScript.response(cseq: 5)),
        ])
        let (_, err) = runClient(RTSPConfig(url: url, credentials: creds), stream)
        XCTAssertTrue(stream.unexpected.isEmpty)
        return (stream.requests, err)
    }

    func assertPinned(contentBase: String?, videoControl: String, sessionControl: String = "*",
                      setup: String, play: String, file: StaticString = #filePath, line: UInt = #line) {
        let (reqs, err) = runHostile(contentBase: contentBase, videoControl: videoControl, sessionControl: sessionControl)
        XCTAssertEqual(err as? NetError, .closed, file: file, line: line)
        XCTAssertEqual(reqs.map(\.method), ["OPTIONS", "DESCRIBE", "DESCRIBE", "SETUP", "PLAY"], file: file, line: line)
        XCTAssertEqual(reqs.dropFirst(3).map(\.uri), [setup, play], file: file, line: line)
        for r in reqs.dropFirst(2) {
            XCTAssertEqual(RTSPURL.parse(r.uri), RTSPURL(host: "192.168.1.10", port: 554), file: file, line: line)
            assertDigest(r, file: file, line: line)
        }
    }

    func testHostileControlToOtherHostIsPinnedToCamera() {
        assertPinned(contentBase: nil, videoControl: "rtsp://evil.example/track1?x=1",
                     setup: "rtsp://192.168.1.10:554/track1?x=1", play: url)
    }

    func testHostileControlToOtherPortIsPinnedToCamera() {
        assertPinned(contentBase: nil, videoControl: "rtsp://192.168.1.10:8554/track1",
                     setup: "rtsp://192.168.1.10:554/track1", play: url)
    }

    func testHostileContentBaseIsPinnedToCamera() {
        assertPinned(contentBase: "rtsp://user:pw@evil.example:9999/stream1/", videoControl: "track1",
                     setup: "rtsp://192.168.1.10:554/stream1/track1", play: "rtsp://192.168.1.10:554/stream1/")
    }

    func testHostileSessionControlIsPinnedToCamera() {
        assertPinned(contentBase: nil, videoControl: "track1", sessionControl: "rtsps://evil.example",
                     setup: url + "/track1", play: "rtsp://192.168.1.10:554")
    }

    func testControlWithSpacesIsRejected() {
        let (reqs, err) = runHostile(contentBase: nil, videoControl: "track1 RTSP/1.0\r\nX: y")
        guard case .protocolError? = err as? RTSPError else { return XCTFail("\(String(describing: err))") }
        XCTAssertEqual(reqs.map(\.method), ["OPTIONS", "DESCRIBE", "DESCRIBE"])
    }

    func testAbsoluteControlOnSameHostIsNormalised() {
        let stream = ScriptedStream([
            .expect("OPTIONS", reply: RTSPScript.response(cseq: 1)),
            .expect("DESCRIBE", reply: RTSPScript.response(cseq: 2, body: sdp(videoControl: "RTSP://admin:pw@192.168.1.10/stream1/track1", audio: false))),
            .expect("SETUP", reply: RTSPScript.response(cseq: 3, headers: [("Session", "S")]), check: { r in
                XCTAssertEqual(r.uri, "rtsp://192.168.1.10:554/stream1/track1")
            }),
            .expect("PLAY", reply: RTSPScript.response(cseq: 4)),
        ])
        let (_, err) = runClient(RTSPConfig(url: url), stream)
        XCTAssertEqual(err as? NetError, .closed)
        XCTAssertEqual(stream.requests.map(\.method), ["OPTIONS", "DESCRIBE", "SETUP", "PLAY"])
    }

    func testCameraURLIsNormalised() {
        let stream = ScriptedStream([
            .expect("OPTIONS", reply: RTSPScript.response(cseq: 1), check: { r in
                XCTAssertEqual(r.uri, "rtsp://cam.local:554/stream1")
            }),
            .expect("DESCRIBE", reply: RTSPScript.response(404, "Not Found", cseq: 2)),
        ], holdOpen: true)
        _ = runClient(RTSPConfig(url: "RTSP://user:pw@Cam.Local/stream1"), stream)
        XCTAssertEqual(stream.requests.map(\.uri), ["rtsp://cam.local:554/stream1", "rtsp://cam.local:554/stream1"])
    }

    func testAggregatePlayUsesContentBaseAsReceived() {
        let stream = ScriptedStream([
            .expect("OPTIONS", reply: RTSPScript.response(cseq: 1)),
            .expect("DESCRIBE", reply: RTSPScript.response(cseq: 2, headers: [("Content-Base", "rtsp://192.168.1.10:554/live")],
                                                          body: sdp(audio: false))),
            .expect("SETUP", reply: RTSPScript.response(cseq: 3, headers: [("Session", "S")]), check: { r in
                XCTAssertEqual(r.uri, "rtsp://192.168.1.10:554/live/track1")
            }),
            .expect("PLAY", reply: RTSPScript.response(cseq: 4), check: { r in
                XCTAssertEqual(r.uri, "rtsp://192.168.1.10:554/live")
            }),
        ])
        let (_, err) = runClient(RTSPConfig(url: url), stream)
        XCTAssertEqual(err as? NetError, .closed)
        XCTAssertEqual(stream.requests.map(\.method), ["OPTIONS", "DESCRIBE", "SETUP", "PLAY"])
    }

    // MARK: - Reading

    func testMidStreamResponsesAndServerRequestsAreSkipped() {
        let announce = Array("ANNOUNCE rtsp://192.168.1.10/stream1 RTSP/1.0\r\nCSeq: 1\r\nContent-Length: 4\r\n\r\nabcd".utf8)
        let stream = ScriptedStream([
            .expect("OPTIONS", reply: RTSPScript.response(cseq: 1)),
            .expect("DESCRIBE", reply: RTSPScript.response(cseq: 2, body: sdp(audio: false))),
            .expect("SETUP", reply: RTSPScript.response(cseq: 3, headers: [("Session", "S;timeout=30")])),
            // Interleaved data and a stray response arrive before the PLAY response.
            .expect("PLAY", reply: video(1, 1000, idr) + RTSPScript.response(cseq: 77) + RTSPScript.response(cseq: 4)),
            .send(video(2, 2000, slice) + RTSPScript.response(cseq: 99, body: "ok") + announce + video(3, 3000, slice)),
        ])
        let (c, err) = runClient(RTSPConfig(url: url), stream)
        XCTAssertEqual(err as? NetError, .closed)
        XCTAssertEqual(c.frames.map(\.timestamp), [1000, 2000, 3000])
        XCTAssertTrue(stream.unexpected.isEmpty)
    }

    func testAudioPacketsDecoded() {
        let payload: [UInt8] = [0xD5, 0x55, 0x2A, 0xAA, 0x00, 0xFF]
        let stream = ScriptedStream([
            .expect("OPTIONS", reply: RTSPScript.response(cseq: 1)),
            .expect("DESCRIBE", reply: RTSPScript.response(cseq: 2, body: sdp())),
            .expect("SETUP", reply: RTSPScript.response(cseq: 3, headers: [("Session", "S"), ("Transport", "RTP/AVP/TCP;unicast;interleaved=4-5")])),
            .expect("SETUP", reply: RTSPScript.response(cseq: 4, headers: [("Session", "S"), ("Transport", "RTP/AVP/TCP;unicast;interleaved=6-7")])),
            .expect("PLAY", reply: RTSPScript.response(cseq: 5)),
            .send(RTSPScript.interleaved(channel: 6, RTPBuilder.bytes(seq: 1, ts: 0, pt: 8, payload: payload))
                + RTSPScript.interleaved(channel: 7, [0x80, 0xC8, 0, 0])
                + RTSPScript.interleaved(channel: 4, RTPBuilder.bytes(seq: 1, ts: 9, marker: true, payload: idr))),
        ])
        let (c, err) = runClient(RTSPConfig(url: url), stream)
        XCTAssertEqual(err as? NetError, .closed)
        XCTAssertEqual(c.audio.count, 1)
        XCTAssertEqual(c.audio.first?.codec, .pcma)
        XCTAssertEqual(c.audio.first?.sampleRate, 8000)
        XCTAssertEqual(c.audio.first?.samples, G711.decode(payload, codec: .pcma))
        XCTAssertEqual(c.frames.map(\.timestamp), [9])
    }

    func testAudioSetupFailureIsNonFatal() {
        let stream = ScriptedStream([
            .expect("OPTIONS", reply: RTSPScript.response(cseq: 1)),
            .expect("DESCRIBE", reply: RTSPScript.response(cseq: 2, body: sdp())),
            .expect("SETUP", reply: RTSPScript.response(cseq: 3, headers: [("Session", "S")])),
            .expect("SETUP", reply: RTSPScript.response(461, "Unsupported Transport", cseq: 4)),
            .expect("PLAY", reply: RTSPScript.response(cseq: 5)),
        ])
        let (c, err) = runClient(RTSPConfig(url: url), stream)
        XCTAssertEqual(err as? NetError, .closed)
        XCTAssertEqual(c.infos, [StreamInfo(videoCodec: .h264, audio: nil, audioSampleRate: 0)])
    }

    func audioInfo(rtpmap: String) -> [StreamInfo] {
        let stream = ScriptedStream([
            .expect("OPTIONS", reply: RTSPScript.response(cseq: 1)),
            .expect("DESCRIBE", reply: RTSPScript.response(cseq: 2, body: sdp(audioRtpmap: rtpmap))),
            .expect("SETUP", reply: RTSPScript.response(cseq: 3, headers: [("Session", "S")])),
            .expect("SETUP", reply: RTSPScript.response(cseq: 4, headers: [("Session", "S")])),
            .expect("PLAY", reply: RTSPScript.response(cseq: 5)),
        ])
        return runClient(RTSPConfig(url: url), stream).0.infos
    }

    func testAudioSampleRateLimitedToG711Rates() {
        XCTAssertEqual(audioInfo(rtpmap: "8 PCMA/16000").map(\.audioSampleRate), [16000])
        XCTAssertEqual(audioInfo(rtpmap: "8 PCMA/44100").map(\.audioSampleRate), [8000])
        XCTAssertEqual(audioInfo(rtpmap: "8 PCMA/8000").map(\.audioSampleRate), [8000])
    }

    func testAudioSetupProtocolErrorIsFatal() {
        let stream = ScriptedStream([
            .expect("OPTIONS", reply: RTSPScript.response(cseq: 1)),
            .expect("DESCRIBE", reply: RTSPScript.response(cseq: 2, body: sdp())),
            .expect("SETUP", reply: RTSPScript.response(cseq: 3, headers: [("Session", "S")])),
            .expect("SETUP", reply: Array("RTSP/1.0 200 OK\r\nCSeq: 4\r\nContent-Length: 999999999\r\n\r\n".utf8)),
        ], holdOpen: true)
        let (_, err) = runClient(RTSPConfig(url: url), stream)
        guard case .protocolError? = err as? RTSPError else { return XCTFail("\(String(describing: err))") }
    }

    func testTruncatedInterleavedFrameAndGarbageDoNotTrap() {
        let stream = ScriptedStream([
            .expect("OPTIONS", reply: RTSPScript.response(cseq: 1)),
            .expect("DESCRIBE", reply: RTSPScript.response(cseq: 2, body: sdp(audio: false))),
            .expect("SETUP", reply: RTSPScript.response(cseq: 3, headers: [("Session", "S")])),
            .expect("PLAY", reply: RTSPScript.response(cseq: 4)),
            .send(RTSPScript.interleaved(channel: 0, [1, 2, 3]) + Array("garbage\r\n\r\n".utf8) + [0x24, 0, 0xFF, 0xFF, 1, 2]),
        ])
        let (c, err) = runClient(RTSPConfig(url: url), stream)
        XCTAssertEqual(err as? NetError, .closed)
        XCTAssertTrue(c.frames.isEmpty)
    }

    func testOversizedContentLengthIsProtocolError() {
        let reply = Array("RTSP/1.0 200 OK\r\nCSeq: 2\r\nContent-Length: 999999999\r\n\r\n".utf8)
        let stream = ScriptedStream([
            .expect("OPTIONS", reply: RTSPScript.response(cseq: 1)),
            .expect("DESCRIBE", reply: reply),
        ], holdOpen: true)
        let (_, err) = runClient(RTSPConfig(url: url), stream)
        guard case .protocolError? = err as? RTSPError else { return XCTFail("\(String(describing: err))") }
    }

    func testCloseUnblocksRun() {
        let stream = ScriptedStream([
            .expect("OPTIONS", reply: RTSPScript.response(cseq: 1)),
            .expect("DESCRIBE", reply: RTSPScript.response(cseq: 2, body: sdp(audio: false))),
            .expect("SETUP", reply: RTSPScript.response(cseq: 3, headers: [("Session", "S1")])),
            .expect("PLAY", reply: RTSPScript.response(cseq: 4)),
            .send(video(1, 1000, idr)),
        ], holdOpen: true)
        let client = RTSPClient(config: RTSPConfig(url: url), stream: stream)
        let gotFrame = expectation(description: "frame")
        let finished = expectation(description: "run returned")
        let thrown = Box()
        Thread {
            do {
                try client.run(onInfo: { _ in }, onVideo: { _ in gotFrame.fulfill() }, onAudio: { _ in })
            } catch {
                thrown.error = error
            }
            finished.fulfill()
        }.start()
        wait(for: [gotFrame], timeout: 3)
        let start = Date()
        client.close()
        wait(for: [finished], timeout: 1)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        XCTAssertNil(thrown.error)
        XCTAssertTrue(stream.isClosed)
        let teardown = stream.unexpected.first { $0.method == "TEARDOWN" }
        XCTAssertEqual(teardown?.headers["Session"], "S1")
        XCTAssertEqual(teardown?.headers["CSeq"], "5")
    }

    func testCloseBeforeRun() {
        let stream = ScriptedStream([], holdOpen: true)
        let client = RTSPClient(config: RTSPConfig(url: url), stream: stream)
        client.close()
        XCTAssertNoThrow(try client.run(onInfo: { _ in }, onVideo: { _ in }, onAudio: { _ in }))
        XCTAssertTrue(stream.requests.isEmpty)
    }

    // MARK: - URL

    func testRTSPURLParse() {
        XCTAssertEqual(RTSPURL.parse("rtsp://192.168.1.10/stream1").map { [$0.host, "\($0.port)"] }, ["192.168.1.10", "554"])
        XCTAssertEqual(RTSPURL.parse("RTSP://Cam.Local:8554").map { [$0.host, "\($0.port)"] }, ["cam.local", "8554"])
        XCTAssertEqual(RTSPURL.parse("rtsp://user:pa:ss@10.0.0.1:555/x").map { [$0.host, "\($0.port)"] }, ["10.0.0.1", "555"])
        XCTAssertEqual(RTSPURL.parse("rtsp://[fe80::1]:600/x").map { [$0.host, "\($0.port)"] }, ["fe80::1", "600"])
        XCTAssertEqual(RTSPURL.parse("rtsp://[fe80::1]/x")?.port, 554)
        for bad in ["", "http://h/x", "rtsp://", "rtsp:///x", "rtsp://h:0/x", "rtsp://h:70000/x", "rtsp://h:abc/x",
                    "rtsp://fe80::1/x", "rtsp://[fe80::1/x", "rtsp://h h/x", "rtsp://h:/x"] {
            XCTAssertNil(RTSPURL.parse(bad), bad)
        }
    }
}
