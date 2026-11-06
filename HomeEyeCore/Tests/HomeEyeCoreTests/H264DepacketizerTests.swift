import XCTest
@testable import HomeEyeCore

final class H264DepacketizerTests: XCTestCase {
    let sps: [UInt8] = [0x67, 0x42, 0x00, 0x1F, 0xAA]
    let pps: [UInt8] = [0x68, 0xCE, 0x3C, 0x80]
    let idr: [UInt8] = [0x65, 1, 2, 3, 4, 5, 6]
    let slice: [UInt8] = [0x41, 9, 8, 7]

    func pkt(_ seq: UInt16, _ ts: UInt32, _ marker: Bool, _ payload: [UInt8]) -> RTPPacket {
        RTPBuilder.packet(seq: seq, ts: ts, marker: marker, payload: payload)
    }

    func stap(_ nals: [[UInt8]]) -> [UInt8] {
        var out: [UInt8] = [0x78]
        for n in nals { out += [UInt8(n.count >> 8), UInt8(n.count & 0xFF)] + n }
        return out
    }

    func testSingleNALWithSDPParameterSets() {
        let d = H264Depacketizer(parameterSets: [sps, pps])
        let f = d.push(pkt(1, 100, true, idr))
        XCTAssertEqual(f, [VideoFrame(codec: .h264, parameterSets: [sps, pps], nalus: [idr], isKeyframe: true, timestamp: 100)])
    }

    func testStapAWithSPSPPSIDR() {
        let d = H264Depacketizer()
        let f = d.push(pkt(1, 5, true, stap([sps, pps, idr])))
        XCTAssertEqual(f.count, 1)
        XCTAssertEqual(f[0].nalus, [idr])
        XCTAssertEqual(f[0].parameterSets, [sps, pps])
        XCTAssertTrue(f[0].isKeyframe)
    }

    func testFUAAcrossThreePackets() {
        let d = H264Depacketizer(parameterSets: [sps, pps])
        let nal: [UInt8] = [0x65] + (1...30).map { UInt8($0) }
        let body = Array(nal[1...])
        let ind: UInt8 = 0x7C // nri 3, type 28
        XCTAssertTrue(d.push(pkt(1, 9, false, [ind, 0x85] + Array(body[0..<10]))).isEmpty)
        XCTAssertTrue(d.push(pkt(2, 9, false, [ind, 5] + Array(body[10..<20]))).isEmpty)
        let f = d.push(pkt(3, 9, true, [ind, 0x45] + Array(body[20...])))
        XCTAssertEqual(f.count, 1)
        XCTAssertEqual(f[0].nalus, [nal])
    }

    func testMarkerlessTimestampChangeEmits() {
        let d = H264Depacketizer(parameterSets: [sps, pps])
        XCTAssertTrue(d.push(pkt(1, 1, false, idr)).isEmpty)
        let f = d.push(pkt(2, 2, false, slice))
        XCTAssertEqual(f.count, 1)
        XCTAssertEqual(f[0].timestamp, 1)
        let g = d.push(pkt(3, 3, false, slice))
        XCTAssertEqual(g.count, 1)
        XCTAssertEqual(g[0].nalus, [slice])
        XCTAssertFalse(g[0].isKeyframe)
    }

    func testFramesBeforeIDRDropped() {
        let d = H264Depacketizer(parameterSets: [sps, pps])
        XCTAssertTrue(d.push(pkt(1, 1, true, slice)).isEmpty)
        XCTAssertEqual(d.push(pkt(2, 2, true, idr)).count, 1)
        XCTAssertEqual(d.push(pkt(3, 3, true, slice)).count, 1)
    }

    func testNoFramesWithoutParameterSets() {
        let d = H264Depacketizer()
        XCTAssertTrue(d.push(pkt(1, 1, true, idr)).isEmpty)
    }

    func testGapMidFUDropsUntilNextIDR() {
        let d = H264Depacketizer(parameterSets: [sps, pps])
        XCTAssertEqual(d.push(pkt(1, 1, true, idr)).count, 1)
        _ = d.push(pkt(2, 2, false, [0x7C, 0x85, 1, 2]))
        // seq 3 lost
        XCTAssertTrue(d.push(pkt(4, 2, true, [0x7C, 0x45, 3, 4])).isEmpty)
        XCTAssertTrue(d.push(pkt(5, 3, true, slice)).isEmpty)
        XCTAssertEqual(d.push(pkt(6, 4, true, idr)).count, 1)
        XCTAssertEqual(d.push(pkt(7, 5, true, slice)).count, 1)
    }

    func testFUWithoutStartDiscardedAndSequenceWraps() {
        let d = H264Depacketizer(parameterSets: [sps, pps])
        XCTAssertEqual(d.push(pkt(65535, 1, true, idr)).count, 1)
        XCTAssertEqual(d.push(pkt(0, 2, true, slice)).count, 1)
        XCTAssertTrue(d.push(pkt(1, 3, true, [0x7C, 0x41, 1, 2])).isEmpty)
    }

    func testAvccLayout() {
        let f = VideoFrame(codec: .h264, parameterSets: [], nalus: [[1, 2, 3], [4]], isKeyframe: false, timestamp: 0)
        XCTAssertEqual(f.avcc(), [0, 0, 0, 3, 1, 2, 3, 0, 0, 0, 1, 4])
    }

    func testStapABoundsChecked() {
        let d = H264Depacketizer(parameterSets: [sps, pps])
        XCTAssertTrue(d.push(pkt(1, 1, true, [0x78, 0x00, 0xFF, 0x65, 1])).isEmpty)
    }

    func testPaddingAndExtensionParsing() {
        let payload: [UInt8] = [0x65, 1, 2]
        let b = RTPBuilder.bytes(seq: 7, ts: 42, marker: true, pt: 99, payload: payload, csrc: 2, extensionWords: 3, padding: 4)
        let p = RTPPacket(b)
        XCTAssertEqual(p?.payload, payload)
        XCTAssertEqual(p?.sequence, 7)
        XCTAssertEqual(p?.timestamp, 42)
        XCTAssertEqual(p?.payloadType, 99)
        XCTAssertEqual(p?.marker, true)
        XCTAssertEqual(p?.ssrc, 0xDEADBEEF)
    }

    func testMalformedHeadersRejected() {
        XCTAssertNil(RTPPacket([0x80, 96, 0]))
        var b = RTPBuilder.bytes(seq: 1, ts: 1, payload: [1])
        b[0] = 0x40
        XCTAssertNil(RTPPacket(b))
        let ext = RTPBuilder.bytes(seq: 1, ts: 1, payload: [], extensionWords: 5)
        XCTAssertNil(RTPPacket(Array(ext.dropLast(8))))
        var pad = RTPBuilder.bytes(seq: 1, ts: 1, payload: [1], padding: 2)
        pad[pad.count - 1] = 200
        XCTAssertNil(RTPPacket(pad))
    }

    func testRandomBytesDoNotCrash() {
        var rng = SystemRandomNumberGenerator()
        let d = H264Depacketizer()
        for _ in 0..<1000 {
            let n = Int.random(in: 0..<80, using: &rng)
            var bytes = (0..<n).map { _ in UInt8.random(in: 0...255, using: &rng) }
            if n > 0 && Bool.random() { bytes[0] = 0x80 | (bytes[0] & 0x3F) }
            if let p = RTPPacket(bytes) { _ = d.push(p) }
        }
    }
}
