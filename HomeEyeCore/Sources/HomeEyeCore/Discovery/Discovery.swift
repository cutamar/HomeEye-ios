import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public struct DiscoveredCamera: Hashable {
    public let host: String
    public let port: Int
    public let name: String?
    public let hardware: String?

    public init(host: String, port: Int, name: String?, hardware: String?) {
        self.host = host
        self.port = port
        self.name = name
        self.hardware = hardware
    }
}

/// Finds ONVIF cameras on the local network (WS-Discovery probe).
public enum Discovery {
    static let multicastAddress = "239.255.255.250"

    public static func probeMessage(messageID: String = "uuid:" + UUID().uuidString.lowercased()) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope" xmlns:w="http://schemas.xmlsoap.org/ws/2004/08/addressing" xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery" xmlns:dn="http://www.onvif.org/ver10/network/wsdl">
        <e:Header><w:MessageID>\(messageID)</w:MessageID><w:To e:mustUnderstand="true">urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To><w:Action e:mustUnderstand="true">http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action></e:Header>
        <e:Body><d:Probe><d:Types>dn:NetworkVideoTransmitter</d:Types></d:Probe></e:Body></e:Envelope>
        """
    }

    /// All host addresses in the /24 of an IPv4 address, e.g. 10.0.0.42 -> 10.0.0.1...254 (minus itself).
    public static func subnetHosts(_ ipv4: String) -> [String] {
        let parts = ipv4.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4,
              parts.allSatisfy({ !$0.isEmpty && $0.count <= 3 && $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              parts.allSatisfy({ Int($0)! <= 255 }) else { return [] }
        let prefix = parts.prefix(3).joined(separator: ".")
        return (1...254).map { "\(prefix).\($0)" }.filter { $0 != ipv4 }
    }

    public static func parseProbeMatch(_ xml: String, fallbackHost: String?) -> DiscoveredCamera? {
        guard let root = try? XML.parse(xml) else { return nil }
        let xaddrs = (root.text("XAddrs") ?? "").split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let comps = xaddrs.compactMap { URLComponents(string: $0) }
        let chosen = comps.first(where: { $0.host?.contains(".") == true })
        guard let host = chosen?.host ?? fallbackHost else { return nil }
        let port = chosen?.port.flatMap { $0 > 0 ? $0 : nil } ?? 80
        let scopes = (root.text("Scopes") ?? "").split(whereSeparator: { $0.isWhitespace }).map(String.init)
        func scope(_ key: String) -> String? {
            guard let s = scopes.first(where: { $0.contains("/\(key)/") }),
                  let range = s.range(of: "/\(key)/") else { return nil }
            let raw = String(s[range.upperBound...]).replacingOccurrences(of: "+", with: " ")
            return raw.removingPercentEncoding
        }
        return DiscoveredCamera(host: host, port: port, name: scope("name"), hardware: scope("hardware"))
    }

    private static func makeAddr(_ ip: String, port: UInt16) -> sockaddr_in? {
        var addr = sockaddr_in()
        #if canImport(Darwin)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { return nil }
        return addr
    }

    private static func send(_ fd: Int32, _ message: [UInt8], to addr: sockaddr_in) {
        var a = addr
        _ = withUnsafePointer(to: &a) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                sendto(fd, message, message.count, sendFlags, sp, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }

    /// Blocking. Sends probes (multicast and/or unicast) and collects replies.
    public static func probe(
        timeout: TimeInterval = 3,
        unicastTargets: [String] = [],
        port: UInt16 = 3702,
        multicast: Bool = true,
        onFound: @escaping (DiscoveredCamera) -> Void = { _ in }
    ) -> [DiscoveredCamera] {
        let fd = socket(AF_INET, sockDgram, 0)
        guard fd >= 0 else { return [] }
        setNoSigPipe(fd)
        var tv = makeTimeval(0.3)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let message = Array(probeMessage().utf8)
        if multicast, let group = makeAddr(multicastAddress, port: port) {
            // Ignore errors: iOS blocks multicast without the entitlement.
            for _ in 0..<2 { send(fd, message, to: group) }
        }

        let state = SenderState()
        let done = DispatchSemaphore(value: 0)
        let sender = Thread {
            for target in unicastTargets {
                if state.isStopped { break }
                if let addr = makeAddr(target, port: port) { send(fd, message, to: addr) }
            }
            state.finish()
            done.signal()
        }
        sender.start()

        var found: [String: DiscoveredCamera] = [:]
        var order: [DiscoveredCamera] = []
        var buf = [UInt8](repeating: 0, count: 65535)
        let start = Date()
        let hardStop = start.addingTimeInterval(timeout + 10)
        while true {
            let now = Date()
            guard now < hardStop, now < start.addingTimeInterval(timeout) || !state.isFinished else { break }
            var ss = sockaddr_storage()
            var slen = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let n = withUnsafeMutablePointer(to: &ss) { sp in
                sp.withMemoryRebound(to: sockaddr.self, capacity: 1) { rp in
                    recvfrom(fd, &buf, buf.count, 0, rp, &slen)
                }
            }
            if n < 0 {
                let e = errno
                if e == EAGAIN || e == EWOULDBLOCK || e == EINTR { continue }
                break
            }
            guard ss.ss_family == sa_family_t(AF_INET) else { continue }
            var sin = withUnsafePointer(to: &ss) { sp in
                sp.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            }
            var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN) + 1)
            guard inet_ntop(AF_INET, &sin.sin_addr, &ipBuf, socklen_t(ipBuf.count)) != nil else { continue }
            let xml = String(decoding: buf[0..<n], as: UTF8.self)
            guard let cam = parseProbeMatch(xml, fallbackHost: String(cString: ipBuf)),
                  found[cam.host] == nil else { continue }
            found[cam.host] = cam
            order.append(cam)
            onFound(cam)
        }

        state.stop()
        _ = done.wait(timeout: .now() + 1)
        posixClose(fd)
        return order
    }

    /// Probes the phone's /24 (and multicast, which may silently fail on iOS).
    public static func scan(onFound: @escaping (DiscoveredCamera) -> Void) async -> [DiscoveredCamera] {
        let targets = LocalNetwork.primaryIPv4().map(subnetHosts) ?? []
        return await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                cont.resume(returning: probe(unicastTargets: targets, onFound: onFound))
            }
        }
    }
}

private final class SenderState {
    private let lock = NSLock()
    private var stopped = false
    private var finished = false
    var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
    func stop() { lock.lock(); stopped = true; lock.unlock() }
    func finish() { lock.lock(); finished = true; lock.unlock() }
}
