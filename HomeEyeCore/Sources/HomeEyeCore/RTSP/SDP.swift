import Foundation

/// One `m=` section of an SDP document.
public struct SDPMedia {
    public var type: String
    public var payloadType: Int
    /// Uppercased rtpmap encoding name (e.g. "H264", "PCMA").
    public var encoding: String
    public var clockRate: Int
    public var channels: Int
    /// fmtp parameters with lowercased keys.
    public var fmtp: [String: String]
    public var control: String?

    public init(type: String, payloadType: Int, encoding: String, clockRate: Int, channels: Int,
                fmtp: [String: String], control: String?) {
        self.type = type
        self.payloadType = payloadType
        self.encoding = encoding
        self.clockRate = clockRate
        self.channels = channels
        self.fmtp = fmtp
        self.control = control
    }
}

public struct SessionDescription {
    public let sessionControl: String?
    public let media: [SDPMedia]

    public init(sessionControl: String?, media: [SDPMedia]) {
        self.sessionControl = sessionControl
        self.media = media
    }

    /// First H.264 / H.265 media section.
    public var video: SDPMedia? {
        media.first { $0.type == "video" && ($0.encoding == "H264" || $0.encoding == "H265") }
    }

    /// First G.711 (PCMA / PCMU) media section.
    public var audio: SDPMedia? {
        media.first { $0.type == "audio" && ($0.encoding == "PCMA" || $0.encoding == "PCMU") }
    }

    /// Lenient parser: malformed lines are ignored, never traps.
    public static func parse(_ text: String) -> SessionDescription {
        var sessionControl: String?
        var media: [SDPMedia] = []
        var skipping = false

        for rawLine in text.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.count > 2, line[line.index(line.startIndex, offsetBy: 1)] == "=" else { continue }
            let kind = line[line.startIndex]
            let value = String(line.dropFirst(2))

            if kind == "m" {
                // m=<type> <port> <proto> <fmt> ...
                let parts = value.split(separator: " ", omittingEmptySubsequences: true)
                guard parts.count >= 4, let pt = Int(parts[3]) else { skipping = true; continue }
                skipping = false
                var m = SDPMedia(type: parts[0].lowercased(), payloadType: pt, encoding: "", clockRate: 0,
                                 channels: 1, fmtp: [:], control: nil)
                if pt == 0 { m.encoding = "PCMU"; m.clockRate = 8000 }
                if pt == 8 { m.encoding = "PCMA"; m.clockRate = 8000 }
                media.append(m)
            } else if kind == "a" {
                if skipping { continue }
                let (name, attrValue) = splitAttribute(value)
                if name == "control" {
                    if media.isEmpty {
                        sessionControl = attrValue
                    } else if !attrValue.isEmpty {
                        media[media.count - 1].control = attrValue
                    }
                } else if name == "rtpmap", !media.isEmpty {
                    applyRtpmap(attrValue, to: &media[media.count - 1])
                } else if name == "fmtp", !media.isEmpty {
                    applyFmtp(attrValue, to: &media[media.count - 1])
                }
            }
        }
        return SessionDescription(sessionControl: sessionControl, media: media)
    }

    private static func splitAttribute(_ value: String) -> (String, String) {
        guard let colon = value.firstIndex(of: ":") else { return (value.lowercased(), "") }
        let name = value[value.startIndex..<colon].lowercased()
        let rest = value[value.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return (name, rest)
    }

    /// `<pt> <encoding>/<rate>[/<channels>]`
    private static func applyRtpmap(_ value: String, to m: inout SDPMedia) {
        let parts = value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, Int(parts[0]) == m.payloadType else { return }
        let enc = parts[1].split(separator: "/", omittingEmptySubsequences: false)
        guard enc.count >= 2, !enc[0].isEmpty, let rate = Int(enc[1]) else { return }
        m.encoding = enc[0].uppercased()
        m.clockRate = rate
        m.channels = enc.count >= 3 ? (Int(enc[2]) ?? 1) : 1
    }

    /// `<pt> k=v; k=v; flag`
    private static func applyFmtp(_ value: String, to m: inout SDPMedia) {
        let parts = value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, Int(parts[0]) == m.payloadType else { return }
        for item in parts[1].split(separator: ";") {
            let kv = item.trimmingCharacters(in: .whitespaces)
            guard let eq = kv.firstIndex(of: "=") else { continue }
            let key = kv[kv.startIndex..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            guard !key.isEmpty else { continue }
            m.fmtp[key] = kv[kv.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        }
    }
}

extension SDPMedia {
    /// Decoded parameter sets: H.264 `sprop-parameter-sets`, or H.265 VPS, SPS, PPS in that order.
    public var parameterSets: [[UInt8]] {
        var encoded: [String] = []
        switch encoding {
        case "H264":
            if let v = fmtp["sprop-parameter-sets"] {
                encoded = v.split(separator: ",").map(String.init)
            }
        case "H265":
            for key in ["sprop-vps", "sprop-sps", "sprop-pps"] {
                if let v = fmtp[key] { encoded.append(v) }
            }
        default:
            break
        }
        return encoded.compactMap { Self.decodeBase64($0) }
    }

    private static func decodeBase64(_ s: String) -> [UInt8]? {
        var t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        while t.count % 4 != 0 { t.append("=") }
        guard let data = Data(base64Encoded: t), !data.isEmpty else { return nil }
        return [UInt8](data)
    }
}

/// Resolves a media/session `a=control:` value against the base URL.
public func resolveControl(base: String, control: String?) -> String {
    guard let control = control, control != "*", !control.isEmpty else { return base }
    let lower = control.lowercased()
    if lower.hasPrefix("rtsp://") || lower.hasPrefix("rtsps://") { return control }
    var relative = Substring(control)
    while relative.hasPrefix("/") { relative = relative.dropFirst() }
    return base + (base.hasSuffix("/") ? "" : "/") + relative
}
