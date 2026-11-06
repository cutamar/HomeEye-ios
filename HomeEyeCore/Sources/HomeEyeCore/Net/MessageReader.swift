import Foundation

public struct Headers {
    public var fields: [(name: String, value: String)]

    public init(fields: [(name: String, value: String)] = []) {
        self.fields = fields
    }

    /// Case-insensitive, first match.
    public subscript(name: String) -> String? {
        let n = name.lowercased()
        return fields.first { $0.name.lowercased() == n }?.value
    }

    public func all(_ name: String) -> [String] {
        let n = name.lowercased()
        return fields.filter { $0.name.lowercased() == n }.map { $0.value }
    }
}

public struct MessageHead {
    public let startLine: String
    public let headers: Headers

    public init(startLine: String, headers: Headers) {
        self.startLine = startLine
        self.headers = headers
    }

    public var isResponse: Bool {
        startLine.hasPrefix("RTSP/") || startLine.hasPrefix("HTTP/")
    }

    /// Second whitespace-separated token of a response start line.
    public var status: Int? {
        let toks = startLine.split(separator: " ", omittingEmptySubsequences: true)
        guard isResponse, toks.count >= 2 else { return nil }
        return Int(toks[1])
    }
}

/// Buffered reader for line/length-delimited text protocols (HTTP, RTSP).
public final class MessageReader {
    public static let maxLineLength = 8 * 1024
    public static let maxHeaders = 100
    static let bufferSize = 64 * 1024

    private let stream: ByteStream
    private var buffer: [UInt8] = []
    private var pos = 0

    public init(_ stream: ByteStream) {
        self.stream = stream
    }

    /// Refills the buffer; throws `.closed` on EOF.
    private func fill() throws {
        let chunk = try stream.read(maxLength: MessageReader.bufferSize)
        if chunk.isEmpty { throw NetError.closed }
        buffer = chunk
        pos = 0
    }

    private var available: Int { buffer.count - pos }

    public func peekByte() throws -> UInt8 {
        if available == 0 { try fill() }
        return buffer[pos]
    }

    public func readByte() throws -> UInt8 {
        let b = try peekByte()
        pos += 1
        return b
    }

    public func readExact(_ n: Int) throws -> [UInt8] {
        guard n >= 0 else { throw NetError.protocolError("negative length") }
        var out: [UInt8] = []
        out.reserveCapacity(min(n, MessageReader.bufferSize))
        while out.count < n {
            if available == 0 { try fill() }
            let take = min(available, n - out.count)
            out.append(contentsOf: buffer[pos..<(pos + take)])
            pos += take
        }
        return out
    }

    /// Reads a line terminated by LF or CRLF (terminator stripped).
    public func readLine() throws -> String {
        var line: [UInt8] = []
        while true {
            if available == 0 { try fill() }
            let slice = buffer[pos...]
            if let idx = slice.firstIndex(of: 10) {
                line.append(contentsOf: buffer[pos..<idx])
                pos = idx + 1
                if line.count > MessageReader.maxLineLength + 1 { throw NetError.protocolError("line too long") }
                if line.last == 13 { line.removeLast() }
                if line.count > MessageReader.maxLineLength { throw NetError.protocolError("line too long") }
                return String(decoding: line, as: UTF8.self)
            }
            line.append(contentsOf: slice)
            pos = buffer.count
            if line.count > MessageReader.maxLineLength + 1 { throw NetError.protocolError("line too long") }
        }
    }

    /// Reads a start line plus headers. Leading blank lines are skipped.
    public func readHead() throws -> MessageHead {
        var start = try readLine()
        var blanks = 0
        while start.isEmpty {
            blanks += 1
            if blanks > 8 { throw NetError.protocolError("missing start line") }
            start = try readLine()
        }
        var fields: [(name: String, value: String)] = []
        while true {
            let line = try readLine()
            if line.isEmpty { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            if fields.count >= MessageReader.maxHeaders { throw NetError.protocolError("too many headers") }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            fields.append((name: name, value: value))
        }
        return MessageHead(startLine: start, headers: Headers(fields: fields))
    }

    /// Reads until EOF. Throws `.protocolError` past `limit` bytes.
    public func readToEnd(limit: Int = Int.max) throws -> [UInt8] {
        var out: [UInt8] = []
        while true {
            if available > 0 {
                out.append(contentsOf: buffer[pos...])
                pos = buffer.count
                if out.count > limit { throw NetError.protocolError("body too large") }
            }
            do { try fill() } catch NetError.closed { return out }
        }
    }
}
