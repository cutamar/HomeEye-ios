import Foundation
@testable import HomeEyeCore

/// One request written by the client, as seen by `ScriptedStream`.
struct ScriptedRequest {
    let method: String
    let uri: String
    let headers: Headers
}

/// Fake `ByteStream` that answers scripted RTSP requests.
///
/// Each `.expect` step waits for a request with that method, records it, runs `check`
/// and queues `reply`. `.send` steps directly after it are queued too (unsolicited
/// interleaved data or server messages). When the script is exhausted, reads return EOF
/// (`holdOpen: false`) or block until `close()` (`holdOpen: true`).
final class ScriptedStream: ByteStream {
    enum Step {
        case expect(String, reply: [UInt8], check: ((ScriptedRequest) -> Void)? = nil)
        case send([UInt8])
    }

    private let cond = NSCondition()
    private var steps: [Step]
    private var output: [UInt8] = []
    private var closed = false
    private let holdOpen: Bool
    private var _requests: [ScriptedRequest] = []
    private var _unexpected: [ScriptedRequest] = []

    var requests: [ScriptedRequest] { cond.lock(); defer { cond.unlock() }; return _requests }
    /// Requests that did not match the next `.expect` step (keepalives, TEARDOWN, ...).
    var unexpected: [ScriptedRequest] { cond.lock(); defer { cond.unlock() }; return _unexpected }
    var isClosed: Bool { cond.lock(); defer { cond.unlock() }; return closed }

    init(_ steps: [Step], holdOpen: Bool = false) {
        self.steps = steps
        self.holdOpen = holdOpen
        cond.lock()
        queueSends()
        cond.unlock()
    }

    /// Caller holds `cond`.
    private func queueSends() {
        while case .send(let bytes)? = steps.first {
            output += bytes
            steps.removeFirst()
        }
    }

    func write(_ bytes: [UInt8]) throws {
        cond.lock()
        defer { cond.unlock() }
        if closed { throw NetError.closed }
        let req = Self.parse(bytes)
        if case .expect(let method, let reply, let check)? = steps.first, method == req.method {
            steps.removeFirst()
            _requests.append(req)
            check?(req)
            output += reply
            queueSends()
            cond.broadcast()
        } else {
            _unexpected.append(req)
        }
    }

    func read(maxLength: Int) throws -> [UInt8] {
        cond.lock()
        defer { cond.unlock() }
        let deadline = Date().addingTimeInterval(5)
        while true {
            if closed { throw NetError.closed }
            if !output.isEmpty {
                let n = min(maxLength, output.count)
                let chunk = Array(output[0..<n])
                output.removeFirst(n)
                return chunk
            }
            if steps.isEmpty && !holdOpen { return [] }
            if !cond.wait(until: deadline) { throw NetError.timeout }
        }
    }

    func close() {
        cond.lock()
        closed = true
        cond.broadcast()
        cond.unlock()
    }

    private static func parse(_ bytes: [UInt8]) -> ScriptedRequest {
        let text = String(decoding: bytes, as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n")
        let start = lines.first?.split(separator: " ").map(String.init) ?? []
        var fields: [(name: String, value: String)] = []
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            fields.append((name: String(line[..<colon]),
                           value: line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
        }
        return ScriptedRequest(method: start.first ?? "", uri: start.count > 1 ? start[1] : "",
                               headers: Headers(fields: fields))
    }
}

/// Builders for scripted server output.
enum RTSPScript {
    static func response(_ status: Int = 200, _ reason: String = "OK", cseq: Int,
                         headers: [(String, String)] = [], body: String = "") -> [UInt8] {
        var s = "RTSP/1.0 \(status) \(reason)\r\nCSeq: \(cseq)\r\n"
        for (n, v) in headers { s += "\(n): \(v)\r\n" }
        if !body.isEmpty { s += "Content-Length: \(body.utf8.count)\r\n" }
        s += "\r\n" + body
        return Array(s.utf8)
    }

    static func interleaved(channel: UInt8, _ payload: [UInt8]) -> [UInt8] {
        [0x24, channel, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)] + payload
    }
}
