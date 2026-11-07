import XCTest
@testable import HomeEyeCore

final class H265DepacketizerTests: XCTestCase {
    let vps: [UInt8] = [0x40, 0x01, 0x0C, 0x01]
    let sps: [UInt8] = [0x42, 0x01, 0x01, 0x01, 0x60]
    let pps: [UInt8] = [0x44, 0x01, 0xC1, 0x72]
    let idr: [UInt8] = [0x26, 0x01, 1, 2, 3, 4, 5]      // type 19
    let cra: [UInt8] = [0x2A, 0x01, 9, 9]               // type 21
    let slice: [UInt8] = [0x02, 0x01, 9, 8, 7]          // type 1
    var sets: [[UInt8]] { [vps, sps, pps] }

    func pkt(_ seq: UInt16, _ ts: UInt32, _ marker: Bool, _ payload: [UInt8]) -> RTPPacket {
        RTPBuilder.packet(seq: seq, ts: ts, marker: marker, payload: payload)
    }

    func ap(_ nals: [[UInt8]]) -> [UInt8] {
        var out: [UInt8] = [0x60, 0x01]
        for n in nals { out += [UInt8(n.count >> 8), UInt8(n.count & 0xFF)] + n }
        return out
    }

    func testSingleNALWithSDPParameterSets() {
        let d = H265Depacketizer(parameterSets: sets)
        let f = d.push(pkt(1, 100, true, idr))
        XCTAssertEqual(f, [VideoFrame(codec: .h265, parameterSets: sets, nalus: [idr], isKeyframe: true, timestamp: 100)])
    }

    func testAPWithParameterSetsAndIDR() {
        let d = H265Depacketizer()
        let f = d.push(pkt(1, 5, true, ap([vps, sps, pps, idr])))
        XCTAssertEqual(f.count, 1)
        XCTAssertEqual(f[0].nalus, [idr])
        XCTAssertEqual(f[0].parameterSets, sets)
        XCTAssertTrue(f[0].isKeyframe)
    }

    func testFUAcrossThreePackets() {
        let d = H265Depacketizer(parameterSets: sets)
        let body = (1...30).map { UInt8($0) }
        let nal: [UInt8] = [0x26, 0x01] + body
        let hdr: [UInt8] = [0x62, 0x01] // type 49
        XCTAssertTrue(d.push(pkt(1, 9, false, hdr + [0x93] + Array(body[0..<10]))).isEmpty)
        XCTAssertTrue(d.push(pkt(2, 9, false, hdr + [19] + Array(body[10..<20]))).isEmpty)
        let f = d.push(pkt(3, 9, true, hdr + [0x53] + Array(body[20...])))
        XCTAssertEqual(f.count, 1)
        XCTAssertEqual(f[0].nalus, [nal])
        XCTAssertTrue(f[0].isKeyframe)
    }

    func testIRAPDetection() {
        let d = H265Depacketizer(parameterSets: sets)
        XCTAssertTrue(d.push(pkt(1, 1, true, slice)).isEmpty)
        for (i, type) in (16...21).enumerated() {
            let nal: [UInt8] = [UInt8(type << 1), 0x01, 1]
            let f = d.push(pkt(UInt16(2 + i), UInt32(2 + i), true, nal))
            XCTAssertEqual(f.first?.isKeyframe, true, "type \(type)")
        }
        let f = d.push(pkt(8, 8, true, cra))
        XCTAssertEqual(f.first?.isKeyframe, true)
        let g = d.push(pkt(9, 9, true, slice))
        XCTAssertEqual(g.first?.isKeyframe, false)
    }

    func testAUDAndPACIDropped() {
        let d = H265Depacketizer(parameterSets: sets)
        let aud: [UInt8] = [0x46, 0x01, 0x50]
        let f = d.push(pkt(1, 1, true, ap([aud, idr])))
        XCTAssertEqual(f.first?.nalus, [idr])
        XCTAssertTrue(d.push(pkt(2, 2, true, [0x64, 0x01, 1, 2, 3])).isEmpty)
    }

    func testMarkerlessTimestampChangeEmits() {
        let d = H265Depacketizer(parameterSets: sets)
        XCTAssertTrue(d.push(pkt(1, 1, false, idr)).isEmpty)
        let f = d.push(pkt(2, 2, false, slice))
        XCTAssertEqual(f.count, 1)
        XCTAssertEqual(f[0].timestamp, 1)
    }

    func testNoFramesWithoutParameterSets() {
        let d = H265Depacketizer()
        XCTAssertTrue(d.push(pkt(1, 1, true, idr)).isEmpty)
    }

    func testGapMidFUDropsUntilNextIRAP() {
        let d = H265Depacketizer(parameterSets: sets)
        XCTAssertEqual(d.push(pkt(1, 1, true, idr)).count, 1)
        _ = d.push(pkt(2, 2, false, [0x62, 0x01, 0x81, 1, 2]))
        XCTAssertTrue(d.push(pkt(4, 2, true, [0x62, 0x01, 0x41, 3, 4])).isEmpty)
        XCTAssertTrue(d.push(pkt(5, 3, true, slice)).isEmpty)
        XCTAssertEqual(d.push(pkt(6, 4, true, idr)).count, 1)
        XCTAssertEqual(d.push(pkt(7, 5, true, slice)).count, 1)
    }

    func testFUWithoutStartDiscarded() {
        let d = H265Depacketizer(parameterSets: sets)
        XCTAssertEqual(d.push(pkt(1, 1, true, idr)).count, 1)
        XCTAssertTrue(d.push(pkt(2, 2, true, [0x62, 0x01, 0x41, 1, 2])).isEmpty)
    }

    func testFUStateResetByNonFUPacket() {
        let d = H265Depacketizer(parameterSets: sets)
        XCTAssertEqual(d.push(pkt(1, 1, true, idr)).count, 1)
        _ = d.push(pkt(2, 2, false, [0x62, 0x01, 0x81, 1, 2]))
        _ = d.push(pkt(3, 2, false, slice))
        // continuation after an interleaved single NAL must not complete the old FU
        let f = d.push(pkt(4, 2, true, [0x62, 0x01, 0x41, 3]))
        XCTAssertEqual(f.first?.nalus, [slice])
    }

    func testAPBoundsChecked() {
        let d = H265Depacketizer(parameterSets: sets)
        XCTAssertTrue(d.push(pkt(1, 1, true, [0x60, 0x01, 0x00, 0xFF, 0x26, 1])).isEmpty)
    }

    func testTruncatedAPYieldsFirstValidNAL() {
        let d = H265Depacketizer(parameterSets: sets)
        let payload = ap([idr]) + [0x00, 0x50, 0x02, 1]
        XCTAssertEqual(d.push(pkt(1, 1, true, payload)).first?.nalus, [idr])
    }

    func testShortPayloadsIgnored() {
        let d = H265Depacketizer(parameterSets: sets)
        XCTAssertTrue(d.push(pkt(1, 1, true, [])).isEmpty)
        XCTAssertTrue(d.push(pkt(2, 1, true, [0x26])).isEmpty)
        XCTAssertTrue(d.push(pkt(3, 1, true, [0x62, 0x01])).isEmpty)
    }

    func testInBandParameterSetsReplaceSDP() {
        let d = H265Depacketizer(parameterSets: sets)
        let sps2: [UInt8] = [0x42, 0x01, 0x02, 0x03]
        let f = d.push(pkt(1, 1, true, ap([sps2, idr])))
        XCTAssertEqual(f.first?.parameterSets, [vps, sps2, pps])
    }

    func testNestedAggregationTypesDropped() {
        let d = H265Depacketizer(parameterSets: sets)
        let f = d.push(pkt(1, 1, true, ap([[0x60, 0x01, 1, 2], [0x62, 0x01, 0x80, 1], idr])))
        XCTAssertEqual(f.first?.nalus, [idr])
    }

    func testOversizedFUDroppedAndWaitsForKeyframe() {
        let d = H265Depacketizer(parameterSets: sets)
        XCTAssertEqual(d.push(pkt(1, 1, true, idr)).count, 1)
        let chunk = [UInt8](repeating: 7, count: 60000)
        var seq: UInt16 = 2
        _ = d.push(pkt(seq, 2, false, [0x62, 0x01, 0x81] + chunk))
        for _ in 0..<80 {
            seq += 1
            _ = d.push(pkt(seq, 2, false, [0x62, 0x01, 1] + chunk))
        }
        seq += 1
        XCTAssertTrue(d.push(pkt(seq, 2, true, [0x62, 0x01, 0x41, 1])).isEmpty)
        seq += 1
        XCTAssertTrue(d.push(pkt(seq, 3, true, slice)).isEmpty)
        seq += 1
        XCTAssertEqual(d.push(pkt(seq, 4, true, idr)).count, 1)
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
        var rng = SeededRNG(state: 4321)
        let d = H265Depacketizer()
        for _ in 0..<1000 {
            let n = Int.random(in: 0..<80, using: &rng)
            var bytes = (0..<n).map { _ in UInt8.random(in: 0...255, using: &rng) }
            if n > 0 && Bool.random(using: &rng) { bytes[0] = 0x80 | (bytes[0] & 0x3F) }
            if let p = RTPPacket(bytes) { _ = d.push(p) }
        }
    }

    func testRandomContiguousAPFUPayloadsDoNotCrash() {
        var rng = SeededRNG(state: 77)
        let d = H265Depacketizer(parameterSets: sets)
        for i in 0..<2000 {
            let n = Int.random(in: 1..<60, using: &rng)
            var payload = (0..<n).map { _ in UInt8.random(in: 0...255, using: &rng) }
            payload[0] = Bool.random(using: &rng) ? 0x60 : 0x62
            let ts = UInt32(i / 3)
            _ = d.push(pkt(UInt16(truncatingIfNeeded: i), ts, Bool.random(using: &rng), payload))
        }
    }

    func testManyTinyNALsInAPAreBounded() {
        let d = H265Depacketizer(parameterSets: sets)
        // Minimal 2-byte NALs (type 1): 4 bytes per entry.
        let tiny: [UInt8] = [0x00, 0x02, 0x02, 0x01]
        let payload: [UInt8] = [0x60, 0x01] + Array((0..<15_000).map { _ in tiny }.joined())
        XCTAssertTrue(d.push(pkt(1, 1, false, payload)).isEmpty)
        XCTAssertTrue(d.push(pkt(2, 1, true, slice)).isEmpty)
        XCTAssertEqual(d.push(pkt(3, 2, true, idr)).first?.nalus, [idr])
    }
}
