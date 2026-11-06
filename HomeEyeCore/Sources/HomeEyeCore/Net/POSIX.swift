import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// Internal shim hiding Glibc/Darwin differences in the socket API.

#if canImport(Glibc)
let sockStream: Int32 = Int32(SOCK_STREAM.rawValue)
let sockDgram: Int32 = Int32(SOCK_DGRAM.rawValue)
let sendFlags: Int32 = Int32(MSG_NOSIGNAL)
#else
let sockStream: Int32 = SOCK_STREAM
let sockDgram: Int32 = SOCK_DGRAM
let sendFlags: Int32 = 0
#endif

let shutRdWr: Int32 = Int32(SHUT_RDWR)
let ipprotoTCP: Int32 = Int32(IPPROTO_TCP)
let pollOut: Int16 = Int16(POLLOUT)

/// Closes a file descriptor (avoids clashing with methods named `close`).
@discardableResult
func posixClose(_ fd: Int32) -> Int32 {
    #if canImport(Glibc)
    return Glibc.close(fd)
    #else
    return Darwin.close(fd)
    #endif
}

/// Darwin has no MSG_NOSIGNAL; a write to a closed socket would raise SIGPIPE and kill the app.
func setNoSigPipe(_ fd: Int32) {
    #if canImport(Darwin)
    var on: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    #endif
}

func makeTimeval(_ seconds: TimeInterval) -> timeval {
    let s = seconds.isNaN ? 0 : min(max(0, seconds), 1e9)
    let whole = s.rounded(.down)
    let micros = ((s - whole) * 1_000_000).rounded(.down)
    return timeval(tv_sec: .init(whole), tv_usec: .init(micros))
}

/// connect(2) under a name that does not clash with `TCPSocket.connect`.
func posixConnect(_ fd: Int32, _ addr: UnsafePointer<sockaddr>?, _ len: socklen_t) -> Int32 {
    #if canImport(Glibc)
    return Glibc.connect(fd, addr, len)
    #else
    return Darwin.connect(fd, addr, len)
    #endif
}
