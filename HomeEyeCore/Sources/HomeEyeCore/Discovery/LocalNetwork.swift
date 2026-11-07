import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum LocalNetwork {
    /// The phone's most likely LAN IPv4 address: `en0` first, then any private-range
    /// address, then any non-loopback address. Nil when there is none.
    public static func primaryIPv4() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var all: [(name: String, ip: String)] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            let flags = UInt32(ifa.pointee.ifa_flags)
            // IFF_UP = 0x1, IFF_LOOPBACK = 0x8 (same values on Linux and Darwin)
            guard flags & 0x1 != 0, flags & 0x8 == 0 else { continue }
            guard let addr = ifa.pointee.ifa_addr,
                  addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            var sin = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN) + 1)
            guard inet_ntop(AF_INET, &sin.sin_addr, &buf, socklen_t(buf.count)) != nil else { continue }
            all.append((String(cString: ifa.pointee.ifa_name), String(cString: buf)))
        }

        if let en0 = all.first(where: { $0.name == "en0" }) { return en0.ip }
        #if canImport(Darwin)
        // Wi-Fi (en*) or a bridge only; with Wi-Fi off, don't probe a cellular/VPN subnet.
        return all.first(where: { $0.name.hasPrefix("en") || $0.name.hasPrefix("bridge") })?.ip
        #else
        if let priv = all.first(where: { isPrivate($0.ip) }) { return priv.ip }
        return all.first?.ip
        #endif
    }

    static func isPrivate(_ ip: String) -> Bool {
        let p = ip.split(separator: ".").compactMap { Int($0) }
        guard p.count == 4 else { return false }
        return p[0] == 10 || (p[0] == 172 && (16...31).contains(p[1])) || (p[0] == 192 && p[1] == 168)
    }
}
