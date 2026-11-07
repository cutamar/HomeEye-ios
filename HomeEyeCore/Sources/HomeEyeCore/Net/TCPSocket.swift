import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum NetError: Error, Equatable {
    case unreachable(String)
    case timeout
    case closed
    case io(Int32)
    case protocolError(String)
}

public protocol ByteStream: AnyObject {
    func write(_ bytes: [UInt8]) throws
    /// Returns [] on EOF. Throws `.timeout` when the read timeout elapses.
    func read(maxLength: Int) throws -> [UInt8]
    /// Idempotent; safe to call from another thread to unblock a pending read.
    func close()
}

public final class TCPSocket: ByteStream {
    private let lock = NSLock()
    private var fd: Int32
    /// Set by `close()`. The descriptor is only released once no read/write is in flight,
    /// so a recycled fd number can never be hit by a stale I/O call.
    private var closed = false
    private var inFlight = 0

    /// Receive timeout in seconds (SO_RCVTIMEO). 0 means no timeout.
    public var readTimeout: TimeInterval = 8 {
        didSet { applyReadTimeout() }
    }

    private init(fd: Int32) {
        self.fd = fd
        applyReadTimeout()
    }

    deinit {
        if fd >= 0 { posixClose(fd) }
    }

    private func applyReadTimeout() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, fd >= 0 else { return }
        var tv = makeTimeval(readTimeout)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Registers an in-flight I/O call and returns the fd, or throws `.closed`.
    private func beginIO() throws -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        if closed || fd < 0 { throw NetError.closed }
        inFlight += 1
        return fd
    }

    private func endIO() {
        lock.lock()
        defer { lock.unlock() }
        inFlight -= 1
        if closed && inFlight == 0 && fd >= 0 {
            posixClose(fd)
            fd = -1
        }
    }

    private var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    public static func connect(host: String, port: Int, timeout: TimeInterval) throws -> TCPSocket {
        guard port > 0, port <= 65535 else { throw NetError.unreachable("Invalid port \(port)") }
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = sockStream
        var res: UnsafeMutablePointer<addrinfo>?
        let gai = getaddrinfo(host, String(port), &hints, &res)
        guard gai == 0, let first = res else {
            let msg = gai != 0 ? String(cString: gai_strerror(gai)) : "no address"
            throw NetError.unreachable("Cannot resolve \(host): \(msg)")
        }
        defer { freeaddrinfo(first) }

        let deadline = Date().addingTimeInterval(timeout)
        var lastError = "Cannot connect to \(host):\(port)"
        var p: UnsafeMutablePointer<addrinfo>? = first
        while let ai = p {
            p = ai.pointee.ai_next
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                lastError = "Connection to \(host):\(port) timed out"
                break
            }
            do {
                let fd = try connectOne(ai.pointee, timeout: remaining)
                return TCPSocket(fd: fd)
            } catch NetError.unreachable(let m) {
                lastError = m
            }
        }
        throw NetError.unreachable(lastError)
    }

    private static func connectOne(_ ai: addrinfo, timeout: TimeInterval) throws -> Int32 {
        let fd = socket(ai.ai_family, ai.ai_socktype, ai.ai_protocol)
        guard fd >= 0 else { throw NetError.unreachable(errnoMessage(errno)) }
        var ok = false
        defer { if !ok { posixClose(fd) } }

        setNoSigPipe(fd)
        var one: Int32 = 1
        _ = setsockopt(fd, ipprotoTCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        var snd = makeTimeval(timeout)
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &snd, socklen_t(MemoryLayout<timeval>.size))

        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw NetError.unreachable(errnoMessage(errno))
        }

        var rc = posixConnect(fd, ai.ai_addr, ai.ai_addrlen)
        while rc != 0 && errno == EINTR { rc = posixConnect(fd, ai.ai_addr, ai.ai_addrlen) }
        if rc != 0 {
            guard errno == EINPROGRESS else { throw NetError.unreachable(errnoMessage(errno)) }
            var pfd = pollfd(fd: fd, events: pollOut, revents: 0)
            let deadline = Date().addingTimeInterval(timeout)
            var pr: Int32
            repeat {
                let ms = Int32(max(0, min(deadline.timeIntervalSinceNow, 3600)) * 1000.0)
                pr = poll(&pfd, 1, ms)
            } while pr < 0 && errno == EINTR
            if pr == 0 { throw NetError.unreachable("Connection timed out") }
            if pr < 0 { throw NetError.unreachable(errnoMessage(errno)) }
            var soErr: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &len) == 0 else {
                throw NetError.unreachable(errnoMessage(errno))
            }
            if soErr != 0 { throw NetError.unreachable(errnoMessage(soErr)) }
        }
        guard fcntl(fd, F_SETFL, flags) == 0 else { throw NetError.unreachable(errnoMessage(errno)) }
        ok = true
        return fd
    }

    private static func errnoMessage(_ e: Int32) -> String {
        String(cString: strerror(e))
    }

    public func write(_ bytes: [UInt8]) throws {
        let f = try beginIO()
        defer { endIO() }
        var sent = 0
        while sent < bytes.count {
            if isClosed { throw NetError.closed }
            let n = bytes.withUnsafeBufferPointer { buf in
                send(f, buf.baseAddress! + sent, buf.count - sent, sendFlags)
            }
            if n < 0 {
                let e = errno
                if e == EINTR { continue }
                if e == EAGAIN || e == EWOULDBLOCK { throw NetError.timeout }
                if e == EPIPE || e == ECONNRESET || e == EBADF { throw NetError.closed }
                throw NetError.io(e)
            }
            sent += n
        }
    }

    public func read(maxLength: Int) throws -> [UInt8] {
        guard maxLength > 0 else { return [] }
        let f = try beginIO()
        defer { endIO() }
        var buf = [UInt8](repeating: 0, count: maxLength)
        while true {
            if isClosed { throw NetError.closed }
            let n = recv(f, &buf, maxLength, 0)
            if n >= 0 {
                buf.removeSubrange(n..<buf.count)
                return buf
            }
            let e = errno
            if e == EINTR { continue }
            if e == EAGAIN || e == EWOULDBLOCK { throw NetError.timeout }
            if isClosed || e == EBADF { throw NetError.closed }
            if e == ECONNRESET { throw NetError.closed }
            throw NetError.io(e)
        }
    }

    /// Unblocks pending I/O via shutdown; the descriptor itself is closed once idle.
    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        guard fd >= 0 else { return }
        _ = shutdown(fd, shutRdWr)
        if inFlight == 0 {
            posixClose(fd)
            fd = -1
        }
    }
}
