import Foundation

public struct RTSPConfig {
    public var url: String
    public var credentials: Credentials?
    public var connectTimeout: TimeInterval
    public var readTimeout: TimeInterval
    public var wantAudio: Bool
    /// When true, a camera that only offers Basic auth is treated as `.unauthorized`
    /// (credentials are never sent in the clear). Set it once the camera is known to use Digest.
    public var refuseBasic: Bool

    public init(url: String, credentials: Credentials? = nil, connectTimeout: TimeInterval = 8,
                readTimeout: TimeInterval = 8, wantAudio: Bool = true, refuseBasic: Bool = false) {
        self.url = url
        self.credentials = credentials
        self.connectTimeout = connectTimeout
        self.readTimeout = readTimeout
        self.wantAudio = wantAudio
        self.refuseBasic = refuseBasic
    }
}

public enum RTSPError: Error, Equatable {
    case unauthorized
    case badStatus(Int, String)
    case noVideoTrack
    case unsupportedCodec(String)
    case protocolError(String)
}

/// Authentication scheme the session ended up using.
public enum AuthScheme: Equatable {
    case none
    case basic
    case digest
}

public struct StreamInfo: Equatable {
    public let videoCodec: VideoCodec
    public let audio: AudioCodec?
    /// 0 when there is no audio.
    public let audioSampleRate: Int
    public let authScheme: AuthScheme

    public init(videoCodec: VideoCodec, audio: AudioCodec?, audioSampleRate: Int, authScheme: AuthScheme = .none) {
        self.videoCodec = videoCodec
        self.audio = audio
        self.audioSampleRate = audioSampleRate
        self.authScheme = authScheme
    }
}

public struct AudioPacket {
    public let codec: AudioCodec
    public let sampleRate: Int
    public let samples: [Int16]

    public init(codec: AudioCodec, sampleRate: Int, samples: [Int16]) {
        self.codec = codec
        self.sampleRate = sampleRate
        self.samples = samples
    }
}

/// Host and port of an `rtsp://` URL. Host is lowercased, without IPv6 brackets.
public struct RTSPURL: Equatable {
    public let host: String
    public let port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    public static func parse(_ s: String) -> RTSPURL? {
        let scheme = "rtsp://"
        guard s.lowercased().hasPrefix(scheme) else { return nil }
        let rest = s.dropFirst(scheme.count)
        var authority = rest.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        if let at = authority.lastIndex(of: "@") {
            authority = authority[authority.index(after: at)...]
        }
        let host: Substring
        var portText: Substring?
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else { return nil }
            host = authority[authority.index(after: authority.startIndex)..<close]
            let after = authority[authority.index(after: close)...]
            if !after.isEmpty {
                guard after.hasPrefix(":") else { return nil }
                portText = after.dropFirst()
            }
        } else {
            let parts = authority.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count <= 2 else { return nil }
            host = parts[0]
            if parts.count == 2 { portText = parts[1] }
        }
        guard !host.isEmpty, !host.unicodeScalars.contains(where: { $0.value <= 0x20 || $0.value == 0x7f }) else {
            return nil
        }
        var port = 554
        if let p = portText {
            guard !p.isEmpty, p.count <= 5, p.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let n = Int(p), n >= 1, n <= 65535 else { return nil }
            port = n
        }
        return RTSPURL(host: host.lowercased(), port: port)
    }
}

/// RTSP over TCP (interleaved RTP) client for one stream. `run` blocks the calling thread.
public final class RTSPClient {
    static let maxBody = 1024 * 1024

    private let config: RTSPConfig
    private let stream: ByteStream
    private let reader: MessageReader
    private let target: RTSPURL?

    // Shared with `close()`, guarded by `lock`. Writes happen under the lock too.
    private let lock = NSLock()
    private var cseq = 0
    private var authenticator: Authenticator?
    private var authScheme: AuthScheme = .none
    private var session: String?
    private var closed = false

    // Reader-thread state.
    private var supportsGetParameter = false
    private var sessionURI = ""
    private var videoChannel: UInt8?
    private var audioChannel: UInt8?
    private var depacketizer: VideoDepacketizer?
    private var audioCodec: AudioCodec?
    private var audioSampleRate = 0

    private struct Response {
        let status: Int
        let reason: String
        let headers: Headers
        let body: [UInt8]
    }

    private enum Message {
        case data(channel: UInt8, payload: [UInt8])
        case response(Response, cseq: Int?)
        case other
    }

    public init(config: RTSPConfig, stream: ByteStream) {
        self.config = config
        self.stream = stream
        self.reader = MessageReader(stream)
        self.target = RTSPURL.parse(config.url)
    }

    private var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    /// Handshakes, then delivers media until the stream fails (throws) or `close()` is called (returns).
    public func run(onInfo: (StreamInfo) -> Void, onVideo: (VideoFrame) -> Void, onAudio: (AudioPacket) -> Void) throws {
        do {
            if isClosed { return }
            let timeout = try handshake(onInfo: onInfo, onVideo: onVideo, onAudio: onAudio)
            let interval = max(Double(timeout) / 2 - 5, 5)
            var nextKeepalive = Date().addingTimeInterval(interval)
            while !isClosed {
                if Date() >= nextKeepalive {
                    _ = try send(supportsGetParameter ? "GET_PARAMETER" : "OPTIONS", uri: sessionURI, headers: [])
                    nextKeepalive = Date().addingTimeInterval(interval)
                }
                if case let .data(ch, payload) = try readMessage() {
                    deliver(channel: ch, payload: payload, onVideo: onVideo, onAudio: onAudio)
                }
            }
        } catch {
            if isClosed { return }
            throw error
        }
    }

    /// Best-effort TEARDOWN, then closes the stream. Safe from any thread; `run` then returns.
    public func close() {
        lock.lock()
        let wasClosed = closed
        closed = true
        let hasSession = session != nil
        let uri = sessionURI.isEmpty ? config.url : sessionURI
        lock.unlock()
        if wasClosed { return }
        if hasSession {
            _ = try? sendLocked("TEARDOWN", uri: uri, headers: [], ignoreClosed: true)
        }
        stream.close()
    }

    // MARK: - Handshake

    /// Returns the session timeout in seconds.
    private func handshake(onInfo: (StreamInfo) -> Void, onVideo: (VideoFrame) -> Void,
                           onAudio: (AudioPacket) -> Void) throws -> Int {
        let url = try pinToCamera(config.url)

        let options = try exchange("OPTIONS", uri: url, headers: [], onVideo: onVideo, onAudio: onAudio)
        if options.status == 401 {
            try? authenticate(from: options)
        } else if (200..<300).contains(options.status), let pub = options.headers["Public"] {
            supportsGetParameter = pub.split(separator: ",").contains {
                $0.trimmingCharacters(in: .whitespaces).uppercased() == "GET_PARAMETER"
            }
        }

        let describe = try request("DESCRIBE", uri: url, headers: [("Accept", "application/sdp")],
                                   onVideo: onVideo, onAudio: onAudio)
        let headerBase = try (describe.headers["Content-Base"] ?? describe.headers["Content-Location"]).map(pinToCamera)
        // Relative controls resolve against a base with a trailing slash.
        var base = headerBase ?? url
        if !base.hasSuffix("/") { base += "/" }

        let sdp = SessionDescription.parse(String(decoding: describe.body, as: UTF8.self))
        guard let video = sdp.video else {
            if let first = sdp.media.first(where: { $0.type == "video" }) {
                throw RTSPError.unsupportedCodec(first.encoding.isEmpty ? "unknown" : first.encoding)
            }
            throw RTSPError.noVideoTrack
        }
        let videoCodec: VideoCodec = video.encoding == "H265" ? .h265 : .h264

        // Video SETUP
        let videoURI = try pinToCamera(resolveControl(base: base, control: video.control))
        let setup = try request("SETUP", uri: videoURI,
                                headers: [("Transport", "RTP/AVP/TCP;unicast;interleaved=0-1")],
                                onVideo: onVideo, onAudio: onAudio)
        guard let sessionHeader = setup.headers["Session"] else {
            throw RTSPError.protocolError("missing Session header")
        }
        let (sessionId, timeout) = try Self.parseSession(sessionHeader)
        lock.lock()
        session = sessionId
        lock.unlock()
        videoChannel = Self.interleavedChannel(setup.headers["Transport"]) ?? 0
        let sets = video.parameterSets
        depacketizer = videoCodec == .h265 ? H265Depacketizer(parameterSets: sets) : H264Depacketizer(parameterSets: sets)

        // Optional audio SETUP
        if config.wantAudio, let audio = sdp.audio, let codec = AudioCodec(rawValue: audio.encoding) {
            let audioURI = try pinToCamera(resolveControl(base: base, control: audio.control))
            do {
                let r = try request("SETUP", uri: audioURI,
                                    headers: [("Transport", "RTP/AVP/TCP;unicast;interleaved=2-3")],
                                    onVideo: onVideo, onAudio: onAudio)
                let ch = Self.interleavedChannel(r.headers["Transport"]) ?? 2
                if ch != videoChannel {
                    audioChannel = ch
                    audioCodec = codec
                    audioSampleRate = audio.clockRate == 16000 ? 16000 : 8000
                }
            } catch RTSPError.badStatus, RTSPError.unauthorized {
                // Audio is optional; keep going with video only.
            }
        }

        // PLAY
        // Aggregate control uses Content-Base/Location as received, else the URL (as live555/FFmpeg do);
        // the slash-appended base is only for resolving relative controls.
        let playURI: String
        if let c = sdp.sessionControl, !c.isEmpty, c != "*" {
            playURI = try pinToCamera(resolveControl(base: base, control: c))
        } else {
            playURI = headerBase ?? url
        }
        lock.lock()
        sessionURI = playURI
        let scheme = authScheme
        lock.unlock()
        onInfo(StreamInfo(videoCodec: videoCodec, audio: audioCodec,
                          audioSampleRate: audioCodec == nil ? 0 : audioSampleRate, authScheme: scheme))
        _ = try request("PLAY", uri: playURI, headers: [("Range", "npt=0.000-")], onVideo: onVideo, onAudio: onAudio)
        return timeout
    }

    /// Rejects URIs that would inject into the request line, and rebuilds every absolute URL as
    /// `rtsp://<camera host>:<port><path+query>`. Userinfo and any other host or port are dropped,
    /// so request lines and Digest `uri` values are canonical and only ever name the configured camera.
    private func pinToCamera(_ uri: String) throws -> String {
        guard !uri.isEmpty, !uri.unicodeScalars.contains(where: { $0.value <= 0x20 || $0.value == 0x7f }) else {
            throw RTSPError.protocolError("invalid request URI")
        }
        guard let target = target else { throw RTSPError.protocolError("invalid camera URL") }
        let lower = uri.lowercased()
        guard let scheme = ["rtsp://", "rtsps://"].first(where: { lower.hasPrefix($0) }) else {
            throw RTSPError.protocolError("unsupported control URL")
        }
        let rest = uri.dropFirst(scheme.count)
        let tail = rest.drop { $0 != "/" && $0 != "?" && $0 != "#" }
        let host = target.host.contains(":") ? "[\(target.host)]" : target.host
        return "rtsp://\(host):\(target.port)\(tail)"
    }

    private func authenticate(from response: Response) throws {
        guard let creds = config.credentials,
              let challenge = AuthChallenge.parse(response.headers.all("WWW-Authenticate")) else {
            throw RTSPError.unauthorized
        }
        let scheme: AuthScheme
        switch challenge {
        case .basic:
            // parse() prefers Digest, so this means the camera offered Basic only.
            if config.refuseBasic { throw RTSPError.unauthorized }
            scheme = .basic
        case .digest:
            scheme = .digest
        }
        lock.lock()
        authenticator = Authenticator(credentials: creds, challenge: challenge)
        authScheme = scheme
        lock.unlock()
    }

    /// Sends a request, authenticating and retrying once on 401. Non-2xx throws.
    private func request(_ method: String, uri: String, headers: [(String, String)],
                         onVideo: (VideoFrame) -> Void, onAudio: (AudioPacket) -> Void) throws -> Response {
        var r = try exchange(method, uri: uri, headers: headers, onVideo: onVideo, onAudio: onAudio)
        if r.status == 401 {
            try authenticate(from: r)
            r = try exchange(method, uri: uri, headers: headers, onVideo: onVideo, onAudio: onAudio)
            if r.status == 401 { throw RTSPError.unauthorized }
        }
        guard (200..<300).contains(r.status) else { throw RTSPError.badStatus(r.status, r.reason) }
        return r
    }

    /// Sends one request and waits for the response with its CSeq, delivering interleaved media meanwhile.
    private func exchange(_ method: String, uri: String, headers: [(String, String)],
                          onVideo: (VideoFrame) -> Void, onAudio: (AudioPacket) -> Void) throws -> Response {
        let seq = try send(method, uri: uri, headers: headers)
        while true {
            switch try readMessage() {
            case let .data(ch, payload):
                deliver(channel: ch, payload: payload, onVideo: onVideo, onAudio: onAudio)
            case let .response(r, cseq):
                if let c = cseq, c != seq { continue }
                return r
            case .other:
                continue
            }
        }
    }

    // MARK: - Writing

    @discardableResult
    private func send(_ method: String, uri: String, headers: [(String, String)]) throws -> Int {
        try sendLocked(method, uri: uri, headers: headers, ignoreClosed: false)
    }

    private func sendLocked(_ method: String, uri: String, headers: [(String, String)], ignoreClosed: Bool) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        if closed && !ignoreClosed { throw NetError.closed }
        cseq += 1
        var text = "\(method) \(uri) RTSP/1.0\r\nCSeq: \(cseq)\r\nUser-Agent: HomeEye\r\n"
        if let auth = authenticator {
            text += "Authorization: \(auth.authorization(method: method, uri: uri))\r\n"
        }
        if let s = session { text += "Session: \(s)\r\n" }
        for (n, v) in headers { text += "\(n): \(v)\r\n" }
        text += "\r\n"
        try stream.write(Array(text.utf8))
        return cseq
    }

    // MARK: - Reading

    private func readMessage() throws -> Message {
        if try reader.peekByte() == 0x24 {
            _ = try reader.readByte()
            let channel = try reader.readByte()
            let hi = try reader.readByte()
            let lo = try reader.readByte()
            let payload = try reader.readExact(Int(hi) << 8 | Int(lo))
            return .data(channel: channel, payload: payload)
        }
        let head = try reader.readHead()
        var body: [UInt8] = []
        if let cl = head.headers["Content-Length"] {
            guard let n = Int(cl.trimmingCharacters(in: .whitespaces)), n >= 0, n <= Self.maxBody else {
                throw RTSPError.protocolError("bad Content-Length")
            }
            body = try reader.readExact(n)
        }
        guard head.isResponse, let status = head.status else { return .other }
        let toks = head.startLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        let reason = toks.count > 2 ? String(toks[2]) : ""
        let cseq = head.headers["CSeq"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        return .response(Response(status: status, reason: reason, headers: head.headers, body: body), cseq: cseq)
    }

    private func deliver(channel: UInt8, payload: [UInt8], onVideo: (VideoFrame) -> Void, onAudio: (AudioPacket) -> Void) {
        if channel == videoChannel, let depacketizer = depacketizer {
            guard let packet = RTPPacket(payload) else { return }
            for frame in depacketizer.push(packet) { onVideo(frame) }
        } else if channel == audioChannel, let codec = audioCodec {
            guard let packet = RTPPacket(payload) else { return }
            onAudio(AudioPacket(codec: codec, sampleRate: audioSampleRate, samples: G711.decode(packet.payload, codec: codec)))
        }
    }

    // MARK: - Header parsing

    /// `Session: <id>[;timeout=<s>]` → (id, timeout, default 60).
    static func parseSession(_ value: String) throws -> (String, Int) {
        let parts = value.split(separator: ";", omittingEmptySubsequences: false)
        let id = parts.first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard !id.isEmpty, !id.unicodeScalars.contains(where: { $0.value <= 0x20 || $0.value == 0x7f }) else {
            throw RTSPError.protocolError("invalid Session header")
        }
        var timeout = 60
        for p in parts.dropFirst() {
            let kv = p.trimmingCharacters(in: .whitespaces)
            if kv.lowercased().hasPrefix("timeout="), let t = Int(kv.dropFirst(8)), t > 0, t <= 3600 {
                timeout = t
            }
        }
        return (id, timeout)
    }

    /// First channel of `interleaved=a-b` in a Transport header.
    static func interleavedChannel(_ transport: String?) -> UInt8? {
        guard let transport = transport else { return nil }
        for p in transport.split(separator: ";") {
            let kv = p.trimmingCharacters(in: .whitespaces)
            guard kv.lowercased().hasPrefix("interleaved=") else { continue }
            let first = kv.dropFirst(12).split(separator: "-").first ?? ""
            return UInt8(first.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }
}
