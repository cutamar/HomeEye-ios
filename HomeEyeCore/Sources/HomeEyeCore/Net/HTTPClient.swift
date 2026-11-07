import Foundation

public struct HTTPResponse {
    public let status: Int
    public let headers: Headers
    public let body: [UInt8]

    public init(status: Int, headers: Headers, body: [UInt8]) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

public enum HTTPClient {
    static let maxBody = 4 * 1024 * 1024

    public static func post(
        host: String, port: Int, path: String,
        headers: [(String, String)], body: [UInt8],
        connectTimeout: TimeInterval, readTimeout: TimeInterval,
        totalTimeout: TimeInterval? = nil,
        connector: (String, Int, TimeInterval) throws -> ByteStream = { try TCPSocket.connect(host: $0, port: $1, timeout: $2) }
    ) throws -> HTTPResponse {
        func isClean(_ s: String) -> Bool {
            !s.unicodeScalars.contains { $0.value <= 0x20 || $0.value == 0x7f }
        }
        guard !path.isEmpty, isClean(path) else { throw NetError.protocolError("invalid path") }
        guard !host.isEmpty, isClean(host) else { throw NetError.protocolError("invalid host") }
        // Overall deadline (connect included) so a slow-drip server cannot hold us forever.
        let deadline = Date().addingTimeInterval(totalTimeout ?? (connectTimeout + 4 * readTimeout))
        let stream = try connector(host, port, connectTimeout)
        defer { stream.close() }
        if let tcp = stream as? TCPSocket { tcp.readTimeout = readTimeout }

        var head = "POST \(path) HTTP/1.1\r\n"
        let hostName = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        head += "Host: \(port == 80 ? hostName : "\(hostName):\(port)")\r\n"
        for (n, v) in headers where isValidHeaderName(n) && isValidHeaderValue(v) {
            head += "\(n): \(v)\r\n"
        }
        head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        try stream.write(Array(head.utf8) + body)

        let reader = MessageReader(stream, deadline: deadline)
        var respHead = try reader.readHead()
        var interim = 0
        while let s = respHead.status, s >= 100, s < 200 {
            interim += 1
            if interim > 100 { throw NetError.protocolError("too many interim responses") }
            respHead = try reader.readHead()
        }
        guard respHead.isResponse, let status = respHead.status else {
            throw NetError.protocolError("bad status line")
        }

        let bodyBytes: [UInt8]
        if status == 204 || status == 304 {
            bodyBytes = []
        } else if let te = respHead.headers["Transfer-Encoding"], te.lowercased().contains("chunked") {
            bodyBytes = try readChunked(reader)
        } else if let cl = respHead.headers["Content-Length"] {
            guard let n = Int(cl.trimmingCharacters(in: .whitespaces)), n >= 0, n <= maxBody else {
                throw NetError.protocolError("bad Content-Length")
            }
            bodyBytes = try reader.readExact(n)
        } else {
            bodyBytes = try reader.readToEnd(limit: maxBody)
        }
        return HTTPResponse(status: status, headers: respHead.headers, body: bodyBytes)
    }

    /// Scalar-based checks (not Character-based: "\r\n" is a single Character).
    private static func isValidHeaderName(_ s: String) -> Bool {
        !s.isEmpty && !s.unicodeScalars.contains { $0.value <= 0x20 || $0.value == 0x7f || $0 == ":" }
    }

    private static func isValidHeaderValue(_ s: String) -> Bool {
        !s.unicodeScalars.contains { ($0.value < 0x20 && $0.value != 0x09) || $0.value == 0x7f }
    }

    private static func readChunked(_ reader: MessageReader) throws -> [UInt8] {
        var out: [UInt8] = []
        while true {
            let line = try reader.readLine()
            let sizeText = line.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
                .first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            guard !sizeText.isEmpty, sizeText.count <= 8, let size = Int(sizeText, radix: 16), size >= 0 else {
                throw NetError.protocolError("bad chunk size")
            }
            if size == 0 {
                // Trailers until blank line; tolerate EOF here.
                do {
                    var n = 0
                    while !(try reader.readLine()).isEmpty {
                        n += 1
                        if n > MessageReader.maxHeaders { throw NetError.protocolError("too many trailers") }
                    }
                } catch NetError.closed {}
                return out
            }
            if out.count + size > maxBody { throw NetError.protocolError("body too large") }
            out += try reader.readExact(size)
            _ = try reader.readLine()  // CRLF after chunk data
        }
    }
}
