/// RFC 6184 depacketizer (single NAL, STAP-A, FU-A).
public final class H264Depacketizer: VideoDepacketizer {
    private static let maxNALSize = 4 * 1024 * 1024
    private static let maxPendingBytes = 8 * 1024 * 1024
    private static let maxPendingNALs = 1024
    private static let perNALOverhead = 64

    private var sps: [UInt8]?
    private var pps: [UInt8]?
    private var lastSequence: UInt16?
    private var waitingForKeyframe = true
    private var pending: [[UInt8]] = []
    private var pendingTimestamp: UInt32 = 0
    private var pendingHasIDR = false
    private var fuBuffer: [UInt8]?
    private var pendingBytes = 0

    public init(parameterSets: [[UInt8]] = []) {
        for ps in parameterSets {
            storeParameterSet(ps)
        }
    }

    private func storeParameterSet(_ nal: [UInt8]) {
        guard let first = nal.first else { return }
        switch first & 0x1F {
        case 7: sps = nal
        case 8: pps = nal
        default: break
        }
    }

    public func push(_ packet: RTPPacket) -> [VideoFrame] {
        var frames: [VideoFrame] = []

        if let last = lastSequence, packet.sequence != last &+ 1 {
            discardAll()
        }
        lastSequence = packet.sequence

        if !pending.isEmpty && packet.timestamp != pendingTimestamp {
            if let f = flush() { frames.append(f) }
        }

        let p = packet.payload
        if let first = p.first, first & 0x1F != 28 { fuBuffer = nil }
        if let first = p.first {
            switch first & 0x1F {
            case 1...23:
                add(p, timestamp: packet.timestamp)
            case 24:
                var i = 1
                while i + 2 <= p.count {
                    let size = Int(p[i]) << 8 | Int(p[i + 1])
                    i += 2
                    guard size > 0, i + size <= p.count else { break }
                    add(Array(p[i..<(i + size)]), timestamp: packet.timestamp)
                    i += size
                }
            case 28:
                handleFU(p, timestamp: packet.timestamp)
            default:
                break
            }
        }

        if packet.marker, let f = flush() { frames.append(f) }
        return frames
    }

    private func discardAll() {
        fuBuffer = nil
        pending = []
        pendingBytes = 0
        pendingHasIDR = false
        waitingForKeyframe = true
    }

    private func handleFU(_ p: [UInt8], timestamp: UInt32) {
        guard p.count >= 2 else { return }
        let indicator = p[0]
        let fu = p[1]
        let start = fu & 0x80 != 0
        let end = fu & 0x40 != 0
        if start {
            fuBuffer = [(indicator & 0xE0) | (fu & 0x1F)]
        }
        guard var buf = fuBuffer else { return }
        fuBuffer = nil
        buf.append(contentsOf: p[2...])
        if buf.count > Self.maxNALSize {
            discardAll()
            return
        }
        if end {
            add(buf, timestamp: timestamp)
        } else {
            fuBuffer = buf
        }
    }

    private func add(_ nal: [UInt8], timestamp: UInt32) {
        guard let first = nal.first else { return }
        let type = first & 0x1F
        switch type {
        case 7, 8:
            storeParameterSet(nal)
        case 0, 9, 24...31:
            break
        default:
            if pending.count >= Self.maxPendingNALs || pendingBytes + nal.count + Self.perNALOverhead > Self.maxPendingBytes {
                discardAll()
                return
            }
            pendingBytes += nal.count + Self.perNALOverhead
            pendingTimestamp = timestamp
            if type == 5 { pendingHasIDR = true }
            pending.append(nal)
        }
    }

    private func flush() -> VideoFrame? {
        let nalus = pending
        let hasIDR = pendingHasIDR
        pending = []
        pendingBytes = 0
        pendingHasIDR = false
        guard !nalus.isEmpty, let sps, let pps else { return nil }
        if waitingForKeyframe {
            guard hasIDR else { return nil }
            waitingForKeyframe = false
        }
        return VideoFrame(codec: .h264, parameterSets: [sps, pps], nalus: nalus,
                          isKeyframe: hasIDR, timestamp: pendingTimestamp)
    }
}
