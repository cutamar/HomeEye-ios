import XCTest
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
@testable import HomeEyeCore

final class DiscoveryTests: XCTestCase {
    static let simple = """
    <?xml version="1.0"?><e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope" xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery"><e:Body><d:ProbeMatches><d:ProbeMatch><d:Scopes>onvif://www.onvif.org/name/TP-IPC onvif://www.onvif.org/hardware/Tapo%20C200 onvif://www.onvif.org/Profile/Streaming</d:Scopes><d:XAddrs>http://192.0.2.10:2020/onvif/device_service</d:XAddrs></d:ProbeMatch></d:ProbeMatches></e:Body></e:Envelope>
    """
    static let tapo = """
    <?xml version="1.0" encoding="UTF-8"?>
    <SOAP-ENV:Envelope xmlns:SOAP-ENV="http://www.w3.org/2003/05/soap-envelope" xmlns:wsa="http://schemas.xmlsoap.org/ws/2004/08/addressing" xmlns:wsdd="http://schemas.xmlsoap.org/ws/2005/04/discovery" xmlns:tdn="http://www.onvif.org/ver10/network/wsdl"><SOAP-ENV:Header><wsa:Action SOAP-ENV:mustUnderstand="true">http://schemas.xmlsoap.org/ws/2005/04/discovery/ProbeMatches</wsa:Action></SOAP-ENV:Header><SOAP-ENV:Body><wsdd:ProbeMatches><wsdd:ProbeMatch><wsa:EndpointReference><wsa:Address>uuid:00000000-0000-0000-0000-000000000000</wsa:Address><wsa:ReferenceProperties></wsa:ReferenceProperties><wsa:PortType>ttl</wsa:PortType></wsa:EndpointReference><wsdd:Types>tdn:NetworkVideoTransmitter</wsdd:Types><wsdd:Scopes>onvif://www.onvif.org/name/C200 onvif://www.onvif.org/hardware/C200 onvif://www.onvif.org/Profile/Streaming onvif://www.onvif.org/location/Hong%20Kong</wsdd:Scopes><wsdd:XAddrs>http://192.0.2.10:2020/onvif/device_service</wsdd:XAddrs><wsdd:MetadataVersion>1</wsdd:MetadataVersion></wsdd:ProbeMatch></wsdd:ProbeMatches></SOAP-ENV:Body></SOAP-ENV:Envelope>
    """

    func testParsesProbeMatch() {
        let cam = Discovery.parseProbeMatch(Self.simple, fallbackHost: nil)
        XCTAssertEqual(cam, DiscoveredCamera(host: "192.0.2.10", port: 2020, name: "TP-IPC", hardware: "Tapo C200"))
    }

    func testParsesRealTapoProbeMatch() {
        let cam = Discovery.parseProbeMatch(Self.tapo, fallbackHost: nil)
        XCTAssertEqual(cam?.host, "192.0.2.10")
        XCTAssertEqual(cam?.hardware, "C200")
        XCTAssertEqual(cam?.name, "C200")
    }

    func testPrefersIPv4XAddr() {
        let xml = Self.simple.replacingOccurrences(
            of: "http://192.0.2.10:2020/onvif/device_service",
            with: "http://[fe80::1]:2020/onvif/device_service http://192.0.2.11:8080/onvif/device_service")
        let cam = Discovery.parseProbeMatch(xml, fallbackHost: nil)
        XCTAssertEqual(cam?.host, "192.0.2.11")
        XCTAssertEqual(cam?.port, 8080)
    }

    func testGarbageIsNil() {
        XCTAssertNil(Discovery.parseProbeMatch("not xml at all", fallbackHost: "1.2.3.4"))
        XCTAssertNil(Discovery.parseProbeMatch("", fallbackHost: nil))
    }

    func testNoXAddrsUsesFallbackHost() {
        let xml = Self.simple.replacingOccurrences(
            of: "<d:XAddrs>http://192.0.2.10:2020/onvif/device_service</d:XAddrs>", with: "")
        let cam = Discovery.parseProbeMatch(xml, fallbackHost: "198.51.100.7")
        XCTAssertEqual(cam?.host, "198.51.100.7")
        XCTAssertEqual(cam?.port, 80)
        XCTAssertNil(Discovery.parseProbeMatch(xml, fallbackHost: nil))
    }

    func testSubnetHosts() {
        let hosts = Discovery.subnetHosts("10.0.0.42")
        XCTAssertEqual(hosts.count, 253)
        XCTAssertFalse(hosts.contains("10.0.0.42"))
        XCTAssertEqual(hosts.first, "10.0.0.1")
        XCTAssertEqual(hosts.last, "10.0.0.254")
        XCTAssertEqual(Discovery.subnetHosts("nope"), [])
        XCTAssertEqual(Discovery.subnetHosts("1.2.3"), [])
        XCTAssertEqual(Discovery.subnetHosts("1.2.3.999"), [])
    }

    func testProbeMessage() throws {
        let msg = Discovery.probeMessage(messageID: "uuid:abc")
        let root = try XML.parse(msg)
        XCTAssertEqual(root.text("MessageID"), "uuid:abc")
        XCTAssertTrue(msg.contains("NetworkVideoTransmitter"))
        XCTAssertTrue(Discovery.probeMessage().contains("<w:MessageID>uuid:"))
    }

    func testLoopbackUnicastProbe() throws {
        let fd = socket(AF_INET, sockDgram, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var addr = sockaddr_in()
        #if canImport(Darwin)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        XCTAssertEqual(inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr), 1)
        let bindRes = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                #if canImport(Darwin)
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                #else
                Glibc.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                #endif
            }
        }
        XCTAssertEqual(bindRes, 0)
        var bound = sockaddr_in()
        var blen = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &blen) }
        }
        let port = UInt16(bigEndian: bound.sin_port)
        var tv = makeTimeval(5)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let responder = Thread {
            var buf = [UInt8](repeating: 0, count: 65535)
            var from = sockaddr_in()
            var flen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, &buf, buf.count, 0, $0, &flen)
                }
            }
            if n > 0 {
                let reply = Array(Self.tapo.utf8)
                _ = withUnsafePointer(to: &from) { p in
                    p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, reply, reply.count, 0, $0, flen)
                    }
                }
            }
        }
        responder.start()

        let found = Discovery.probe(timeout: 1, unicastTargets: ["127.0.0.1"], port: port, multicast: false)
        posixClose(fd)
        XCTAssertEqual(found.map(\.host), ["192.0.2.10"])
        XCTAssertEqual(found.first?.port, 2020)
    }

    func testOutOfRangePortIsRejected() {
        for bad in ["99999", "0", "70000"] {
            let xml = Self.simple.replacingOccurrences(of: "192.0.2.10:2020", with: "192.0.2.10:\(bad)")
            XCTAssertNil(Discovery.parseProbeMatch(xml, fallbackHost: nil), bad)
            let fb = Discovery.parseProbeMatch(xml, fallbackHost: "198.51.100.7")
            XCTAssertEqual(fb?.host, "198.51.100.7")
            XCTAssertEqual(fb?.port, 80)
        }
        let two = Self.simple.replacingOccurrences(
            of: "http://192.0.2.10:2020/onvif/device_service",
            with: "http://192.0.2.10:99999/x http://192.0.2.12:81/x")
        XCTAssertEqual(Discovery.parseProbeMatch(two, fallbackHost: nil)?.host, "192.0.2.12")
    }

    func testInvalidPercentEncodingInScopesGivesNilName() {
        let xml = Self.simple.replacingOccurrences(of: "name/TP-IPC", with: "name/%zz")
        let cam = Discovery.parseProbeMatch(xml, fallbackHost: nil)
        XCTAssertEqual(cam?.host, "192.0.2.10")
        XCTAssertNil(cam?.name)
        XCTAssertEqual(cam?.hardware, "Tapo C200")
    }

    func testDeeplyNestedXMLDoesNotCrash() {
        let depth = 20000
        let xml = "<a>" + String(repeating: "<b>", count: depth) + "x" + String(repeating: "</b>", count: depth) + "</a>"
        let cam = Discovery.parseProbeMatch(xml, fallbackHost: "198.51.100.7")
        XCTAssertTrue(cam == nil || cam?.host == "198.51.100.7")
    }

    func testResultCap() {
        let saved = Discovery.maxResults
        Discovery.maxResults = 2
        defer { Discovery.maxResults = saved }
        let fd = socket(AF_INET, sockDgram, 0)
        var addr = sockaddr_in()
        #if canImport(Darwin)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        addr.sin_family = sa_family_t(AF_INET)
        XCTAssertEqual(inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr), 1)
        _ = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                #if canImport(Darwin)
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                #else
                Glibc.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                #endif
            }
        }
        var bound = sockaddr_in()
        var blen = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &blen) }
        }
        let port = UInt16(bigEndian: bound.sin_port)
        var tv = makeTimeval(5)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let responder = Thread {
            var buf = [UInt8](repeating: 0, count: 65535)
            var from = sockaddr_in()
            var flen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &flen) }
            }
            guard n > 0 else { return }
            for i in 1...5 {
                let reply = Array(Self.simple.replacingOccurrences(of: "192.0.2.10", with: "192.0.2.\(i)").utf8)
                _ = withUnsafePointer(to: &from) { p in
                    p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, reply, reply.count, 0, $0, flen) }
                }
            }
        }
        responder.start()
        let found = Discovery.probe(timeout: 1, unicastTargets: ["127.0.0.1"], port: port, multicast: false)
        posixClose(fd)
        XCTAssertEqual(found.count, 2)
    }

    func testPrimaryIPv4DoesNotCrash() {
        _ = LocalNetwork.primaryIPv4()
    }
}
