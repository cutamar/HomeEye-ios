/// RFC 7798 depacketizer (single NAL, AP, FU). No DONL support; PACI is dropped.
public final class H265Depacketizer: VideoDepacketizer {
    private static let maxNALSize = 4 * 1024 * 1024
    private static let maxPendingBytes = 16 * 1024 * 1024

    private var vps: [UInt8]?
    private var sps: [UInt8]?
    private var pps: [UInt8]?
    private var lastSequence: UInt16?
    private var waitingForKeyframe = true
    private var pending: [[UInt8]] = []
    private var pendingTimestamp: UInt32 = 0
    private var pendingHasIRAP = false
    private var fuBuffer: [UInt8]?
    private var pendingBytes = 0

    public init(parameterSets: [[UInt8]] = []) {
        for ps in parameterSets {
            storeParameterSet(ps)
        }
    }

    private static func nalType(_ b0: UInt8) -> UInt8 { (b0 >> 1) & 0x3F }

    private func storeParameterSet(_ nal: [UInt8]) {
        guard nal.count >= 2 else { return }
        switch Self.nalType(nal[0]) {
        case 32: vps = nal
        case 33: sps = nal
        case 34: pps = nal
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
        if p.count >= 2 {
            let type = Self.nalType(p[0])
            if type != 49 { fuBuffer = nil }
            switch type {
            case 0...47:
                add(p, timestamp: packet.timestamp)
            case 48:
                var i = 2
                while i + 2 <= p.count {
                    let size = Int(p[i]) << 8 | Int(p[i + 1])
                    i += 2
                    guard size > 0, i + size <= p.count else { break }
                    add(Array(p[i..<(i + size)]), timestamp: packet.timestamp)
                    i += size
                }
            case 49:
                handleFU(p, timestamp: packet.timestamp)
            default:
                break
            }
        } else {
            fuBuffer = nil
        }

        if packet.marker, let f = flush() { frames.append(f) }
        return frames
    }

    private func discardAll() {
        fuBuffer = nil
        pending = []
        pendingBytes = 0
        pendingHasIRAP = false
        waitingForKeyframe = true
    }

    private func handleFU(_ p: [UInt8], timestamp: UInt32) {
        guard p.count >= 3 else { return }
        let fu = p[2]
        let start = fu & 0x80 != 0
        let end = fu & 0x40 != 0
        let type = fu & 0x3F
        if start {
            fuBuffer = [(p[0] & 0x81) | (type << 1), p[1]]
        }
        guard var buf = fuBuffer else { return }
        fuBuffer = nil
        buf.append(contentsOf: p[3...])
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
        guard nal.count >= 2 else { return }
        let type = Self.nalType(nal[0])
        switch type {
        case 32...34:
            storeParameterSet(nal)
        case 35, 41...63:
            break
        default:
            if pendingBytes + nal.count > Self.maxPendingBytes {
                discardAll()
                return
            }
            pendingBytes += nal.count
            pendingTimestamp = timestamp
            if (16...21).contains(type) { pendingHasIRAP = true }
            pending.append(nal)
        }
    }

    private func flush() -> VideoFrame? {
        let nalus = pending
        let hasIRAP = pendingHasIRAP
        pending = []
        pendingBytes = 0
        pendingHasIRAP = false
        guard !nalus.isEmpty, let vps, let sps, let pps else { return nil }
        if waitingForKeyframe {
            guard hasIRAP else { return nil }
            waitingForKeyframe = false
        }
        return VideoFrame(codec: .h265, parameterSets: [vps, sps, pps], nalus: nalus,
                          isKeyframe: hasIRAP, timestamp: pendingTimestamp)
    }
}
