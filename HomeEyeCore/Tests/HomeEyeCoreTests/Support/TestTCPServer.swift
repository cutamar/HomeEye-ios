import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
@testable import HomeEyeCore

/// One-shot loopback server: accepts a single connection, reads the request head
/// (and Content-Length body), records it, writes a canned response and closes.
final class TestTCPServer {
    private(set) var port: Int = 0
    private var listenFd: Int32 = -1
    private let response: [UInt8]
    private let lock = NSLock()
    private var _request: [UInt8] = []
    private let done = DispatchSemaphore(value: 0)

    var request: [UInt8] { lock.lock(); defer { lock.unlock() }; return _request }

    init(response: [UInt8]) throws {
        self.response = response
        let fd = socket(AF_INET, sockStream, 0)
        guard fd >= 0 else { throw NetError.io(errno) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindRes = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindRes == 0, listen(fd, 1) == 0 else {
            let e = errno
            posixClose(fd)
            throw NetError.io(e)
        }
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        port = Int(UInt16(bigEndian: bound.sin_port))
        listenFd = fd
        let t = Thread { [weak self] in self?.serve() }
        t.start()
    }

    private func serve() {
        lock.lock()
        let lfd = listenFd
        lock.unlock()
        let c = lfd >= 0 ? accept(lfd, nil, nil) : -1
        if c >= 0 {
            var data: [UInt8] = []
            var buf = [UInt8](repeating: 0, count: 4096)
            let term: [UInt8] = [13, 10, 13, 10]
            var headParsed = false
            var want = Int.max
            while data.count < want {
                let n = recv(c, &buf, buf.count, 0)
                if n <= 0 { break }
                data.append(contentsOf: buf[0..<n])
                if !headParsed, let r = data.firstRange(of: term) {
                    headParsed = true
                    let head = String(decoding: data[0..<r.lowerBound], as: UTF8.self).lowercased()
                    var cl = 0
                    for l in head.components(separatedBy: "\r\n") where l.hasPrefix("content-length:") {
                        cl = Int(l.dropFirst(15).trimmingCharacters(in: .whitespaces)) ?? 0
                    }
                    want = r.upperBound + cl
                }
            }
            lock.lock()
            _request = data
            lock.unlock()
            _ = response.withUnsafeBufferPointer { send(c, $0.baseAddress, $0.count, sendFlags) }
            posixClose(c)
        }
        done.signal()
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        if listenFd >= 0 {
            _ = shutdown(listenFd, shutRdWr)
            posixClose(listenFd)
            listenFd = -1
        }
    }

    func waitDone(timeout: TimeInterval = 5) -> Bool {
        done.wait(timeout: .now() + timeout) == .success
    }
}
