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

    struct SeededRNG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    func testRandomBytesDoNotCrash() {
        var rng = SeededRNG(state: 1234)
        let d = H264Depacketizer()
        for _ in 0..<1000 {
            let n = Int.random(in: 0..<80, using: &rng)
            var bytes = (0..<n).map { _ in UInt8.random(in: 0...255, using: &rng) }
            if n > 0 && Bool.random(using: &rng) { bytes[0] = 0x80 | (bytes[0] & 0x3F) }
            if let p = RTPPacket(bytes) { _ = d.push(p) }
        }
    }

    func testRandomContiguousStapAFUAPayloadsDoNotCrash() {
        var rng = SeededRNG(state: 99)
        let d = H264Depacketizer(parameterSets: [sps, pps])
        for i in 0..<2000 {
            let n = Int.random(in: 1..<60, using: &rng)
            var payload = (0..<n).map { _ in UInt8.random(in: 0...255, using: &rng) }
            payload[0] = Bool.random(using: &rng) ? 24 : 28
            let ts = UInt32(i / 3)
            _ = d.push(pkt(UInt16(truncatingIfNeeded: i), ts, Bool.random(using: &rng), payload))
        }
    }

    func testCSRCOverrunRejected() {
        var b = RTPBuilder.bytes(seq: 1, ts: 1, payload: [1])
        b[0] = 0x80 | 0x0F
        XCTAssertNil(RTPPacket(b))
    }

    func testOversizedFUDroppedAndWaitsForKeyframe() {
        let d = H264Depacketizer(parameterSets: [sps, pps])
        XCTAssertEqual(d.push(pkt(1, 1, true, idr)).count, 1)
        let chunk = [UInt8](repeating: 7, count: 60000)
        var seq: UInt16 = 2
        _ = d.push(pkt(seq, 2, false, [0x7C, 0x81] + chunk))
        for _ in 0..<80 {
            seq += 1
            _ = d.push(pkt(seq, 2, false, [0x7C, 0x01] + chunk))
        }
        seq += 1
        XCTAssertTrue(d.push(pkt(seq, 2, true, [0x7C, 0x41, 1])).isEmpty)
        seq += 1
        XCTAssertTrue(d.push(pkt(seq, 3, true, slice)).isEmpty)
        seq += 1
        XCTAssertEqual(d.push(pkt(seq, 4, true, idr)).count, 1)
    }

    func testInBandParameterSetsReplaceSDP() {
        let d = H264Depacketizer(parameterSets: [sps, pps])
        let sps2: [UInt8] = [0x67, 0x64, 0x00, 0x28]
        let pps2: [UInt8] = [0x68, 0xEE, 0x3C]
        let f = d.push(pkt(1, 1, true, stap([sps2, pps2, idr])))
        XCTAssertEqual(f.first?.parameterSets, [sps2, pps2])
        XCTAssertEqual(f.first?.nalus, [idr])
    }

    func testTruncatedStapAYieldsFirstValidNAL() {
        let d = H264Depacketizer(parameterSets: [sps, pps])
        var payload = stap([idr])
        payload += [0x00, 0x50, 0x41, 1]
        let f = d.push(pkt(1, 1, true, payload))
        XCTAssertEqual(f.first?.nalus, [idr])
    }

    func testNestedAggregationTypesDropped() {
        let d = H264Depacketizer(parameterSets: [sps, pps])
        let f = d.push(pkt(1, 1, true, stap([[0x78, 1, 2], idr])))
        XCTAssertEqual(f.first?.nalus, [idr])
    }

    func testManyTinyNALsInStapAAreBounded() {
        let d = H264Depacketizer(parameterSets: [sps, pps])
        // 1-byte NALs (type 1): 3 bytes per entry, ~20k entries per packet.
        let tiny: [UInt8] = [0x00, 0x01, 0x41]
        let payload: [UInt8] = [0x78] + Array((0..<20_000).map { _ in tiny }.joined())
        XCTAssertTrue(d.push(pkt(1, 1, false, payload)).isEmpty)
        // Cap tripped: state was discarded, so a following non-IDR frame yields nothing.
        XCTAssertTrue(d.push(pkt(2, 1, true, [0x41, 1])).isEmpty)
        // Recovers on the next keyframe.
        XCTAssertEqual(d.push(pkt(3, 2, true, idr)).first?.nalus, [idr])
    }
}
