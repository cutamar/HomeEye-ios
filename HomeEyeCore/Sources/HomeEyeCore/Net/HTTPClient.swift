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
        connector: (String, Int, TimeInterval) throws -> ByteStream = { try TCPSocket.connect(host: $0, port: $1, timeout: $2) }
    ) throws -> HTTPResponse {
        let stream = try connector(host, port, connectTimeout)
        defer { stream.close() }
        if let tcp = stream as? TCPSocket { tcp.readTimeout = readTimeout }

        var head = "POST \(path) HTTP/1.1\r\n"
        head += "Host: \(port == 80 ? host : "\(host):\(port)")\r\n"
        for (n, v) in headers where !n.contains("\r") && !n.contains("\n") && !v.contains("\r") && !v.contains("\n") {
            head += "\(n): \(v)\r\n"
        }
        head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        try stream.write(Array(head.utf8) + body)

        let reader = MessageReader(stream)
        var respHead = try reader.readHead()
        while let s = respHead.status, s >= 100, s < 200 {
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
