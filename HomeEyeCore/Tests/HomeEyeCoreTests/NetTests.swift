import XCTest
@testable import HomeEyeCore

private final class FakeStream: ByteStream {
    var input: [UInt8]
    var written: [UInt8] = []
    let chunk: Int
    init(_ s: String, chunk: Int = 7) { input = Array(s.utf8); self.chunk = chunk }
    func write(_ bytes: [UInt8]) throws { written += bytes }
    func read(maxLength: Int) throws -> [UInt8] {
        let n = min(chunk, maxLength, input.count)
        let out = Array(input[0..<n])
        input.removeFirst(n)
        return out
    }
    func close() {}
}

final class NetTests: XCTestCase {
    private func post(_ raw: String, chunk: Int = 7) throws -> (HTTPResponse, FakeStream) {
        let s = FakeStream(raw, chunk: chunk)
        let r = try HTTPClient.post(host: "h", port: 80, path: "/x", headers: [("A", "b")],
                                    body: Array("hi".utf8), connectTimeout: 1, readTimeout: 1,
                                    connector: { _, _, _ in s })
        return (r, s)
    }

    private func assertProtocolError(_ raw: String, file: StaticString = #file, line: UInt = #line) {
        XCTAssertThrowsError(try post(raw), file: file, line: line) {
            guard case NetError.protocolError = $0 else { return XCTFail("\($0)", file: file, line: line) }
        }
    }

    func testRequestFormat() throws {
        let (_, s) = try post("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
        let w = String(decoding: s.written, as: UTF8.self)
        XCTAssertTrue(w.hasPrefix("POST /x HTTP/1.1\r\nHost: h\r\n"))
        XCTAssertTrue(w.contains("A: b\r\n"))
        XCTAssertTrue(w.contains("Content-Length: 2\r\n"))
        XCTAssertTrue(w.contains("Connection: close\r\n"))
        XCTAssertTrue(w.hasSuffix("\r\n\r\nhi"))
    }

    func testHostIncludesNonDefaultPort() throws {
        let s = FakeStream("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
        _ = try HTTPClient.post(host: "h", port: 2020, path: "/", headers: [], body: [],
                                connectTimeout: 1, readTimeout: 1, connector: { _, _, _ in s })
        XCTAssertTrue(String(decoding: s.written, as: UTF8.self).contains("Host: h:2020\r\n"))
    }

    func testContentLength() throws {
        let (r, _) = try post("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nX-A: 1\r\n\r\nhelloEXTRA")
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(String(decoding: r.body, as: UTF8.self), "hello")
        XCTAssertEqual(r.headers["x-a"], "1")
    }

    func testChunked() throws {
        let (r, _) = try post("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6;ext=1\r\n world\r\n0\r\nT: v\r\n\r\n")
        XCTAssertEqual(String(decoding: r.body, as: UTF8.self), "hello world")
    }

    func testChunkedBadSize() {
        assertProtocolError("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n")
    }

    func testContinueSkipped() throws {
        let (r, _) = try post("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 400 Bad\r\nContent-Length: 2\r\n\r\nok")
        XCTAssertEqual(r.status, 400)
        XCTAssertEqual(String(decoding: r.body, as: UTF8.self), "ok")
    }

    func testBareLFAndReadToEOF() throws {
        let (r, _) = try post("HTTP/1.0 200 OK\nServer: x\n\nbody-until-eof")
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(String(decoding: r.body, as: UTF8.self), "body-until-eof")
    }

    func testOversizedLine() {
        assertProtocolError("HTTP/1.1 200 OK\r\nX: \(String(repeating: "a", count: 9000))\r\n\r\n")
    }

    func testTooManyHeaders() {
        let hs = (0..<150).map { "H\($0): v\r\n" }.joined()
        assertProtocolError("HTTP/1.1 200 OK\r\n\(hs)\r\n")
    }

    func testTruncatedIsClosed() {
        XCTAssertThrowsError(try post("HTTP/1.1 200 OK\r\nContent-Le")) { XCTAssertEqual($0 as? NetError, .closed) }
        XCTAssertThrowsError(try post("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nabc")) { XCTAssertEqual($0 as? NetError, .closed) }
        XCTAssertThrowsError(try post("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhe")) { XCTAssertEqual($0 as? NetError, .closed) }
    }

    func testContentLengthTooLarge() {
        assertProtocolError("HTTP/1.1 200 OK\r\nContent-Length: 99999999\r\n\r\n")
        assertProtocolError("HTTP/1.1 200 OK\r\nContent-Length: -1\r\n\r\n")
    }

    func testHeadersCaseInsensitiveAndAll() throws {
        let r = MessageReader(FakeStream("RTSP/1.0 200 OK\r\nCSeq: 1\r\nSet-Cookie: a\r\nset-cookie: b\r\n\r\n"))
        let head = try r.readHead()
        XCTAssertTrue(head.isResponse)
        XCTAssertEqual(head.status, 200)
        XCTAssertEqual(head.headers["cseq"], "1")
        XCTAssertEqual(head.headers.all("SET-COOKIE"), ["a", "b"])
    }

    func testReaderPrimitives() throws {
        let r = MessageReader(FakeStream("abcdef"))
        XCTAssertEqual(try r.peekByte(), 97)
        XCTAssertEqual(try r.readByte(), 97)
        XCTAssertEqual(try r.readExact(3), Array("bcd".utf8))
        XCTAssertEqual(try r.readToEnd(), Array("ef".utf8))
        XCTAssertThrowsError(try r.readByte()) { XCTAssertEqual($0 as? NetError, .closed) }
    }

    func testEndToEndPost() throws {
        let server = try TestTCPServer(response: Array("HTTP/1.1 200 OK\r\nContent-Length: 3\r\nConnection: close\r\n\r\nyes".utf8))
        defer { server.stop() }
        let r = try HTTPClient.post(host: "127.0.0.1", port: server.port, path: "/onvif/device_service",
                                    headers: [("Content-Type", "application/soap+xml")],
                                    body: Array("<x/>".utf8), connectTimeout: 2, readTimeout: 2)
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(String(decoding: r.body, as: UTF8.self), "yes")
        XCTAssertTrue(server.waitDone())
        let req = String(decoding: server.request, as: UTF8.self)
        XCTAssertTrue(req.hasPrefix("POST /onvif/device_service HTTP/1.1\r\n"))
        XCTAssertTrue(req.hasSuffix("<x/>"))
    }

    func testClosedPortIsUnreachableFast() throws {
        let server = try TestTCPServer(response: [])
        let port = server.port
        server.stop()
        let start = Date()
        XCTAssertThrowsError(try TCPSocket.connect(host: "127.0.0.1", port: port, timeout: 2)) {
            guard case NetError.unreachable = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }

    func testBlackholeTimesOut() {
        let start = Date()
        XCTAssertThrowsError(try TCPSocket.connect(host: "192.0.2.1", port: 2020, timeout: 1.5)) {
            guard case NetError.unreachable = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.5)
    }

    func testReadTimeout() throws {
        let server = try TestTCPServer(response: [])
        defer { server.stop() }
        let sock = try TCPSocket.connect(host: "127.0.0.1", port: server.port, timeout: 2)
        defer { sock.close() }
        sock.readTimeout = 0.3
        XCTAssertThrowsError(try sock.read(maxLength: 10)) { XCTAssertEqual($0 as? NetError, .timeout) }
    }

    func testCloseUnblocksPendingReadAndIsIdempotent() throws {
        let server = try TestTCPServer(response: [])
        defer { server.stop() }
        let sock = try TCPSocket.connect(host: "127.0.0.1", port: server.port, timeout: 2)
        sock.readTimeout = 5
        let t0 = Date()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
            sock.close()
            sock.close()
        }
        do {
            let b = try sock.read(maxLength: 10)
            XCTAssertTrue(b.isEmpty)
        } catch {
            XCTAssertEqual(error as? NetError, .closed)
        }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 2)
    }
}
