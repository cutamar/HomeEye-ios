import Foundation

/// `unreachable` is true when nothing answered at all (wrong IP, camera off).
public struct OnvifError: Error, LocalizedError, Equatable {
    public let message: String
    public let unreachable: Bool

    public init(_ message: String, unreachable: Bool = false) {
        self.message = message
        self.unreachable = unreachable
    }

    public var errorDescription: String? { message }
}

public struct DeviceInfo: Equatable {
    public let manufacturer: String
    public let model: String
    public let firmware: String

    public init(manufacturer: String, model: String, firmware: String) {
        self.manufacturer = manufacturer
        self.model = model
        self.firmware = firmware
    }
}

public struct MediaProfile: Equatable {
    public let token: String
    public let name: String
    public let width: Int
    public let height: Int
    public let hasPtz: Bool

    public init(token: String, name: String, width: Int, height: Int, hasPtz: Bool) {
        self.token = token
        self.name = name
        self.width = width
        self.height = height
        self.hasPtz = hasPtz
    }
}

public struct Preset: Hashable, Identifiable {
    public let token: String
    public let name: String
    public var id: String { token }

    public init(token: String, name: String) {
        self.token = token
        self.name = name
    }
}

public protocol SOAPTransport {
    func post(host: String, port: Int, path: String, body: [UInt8], headers: [(String, String)],
              connectTimeout: TimeInterval, timeout: TimeInterval) throws -> HTTPResponse
}

public struct SocketSOAPTransport: SOAPTransport {
    public init() {}

    public func post(host: String, port: Int, path: String, body: [UInt8], headers: [(String, String)],
                     connectTimeout: TimeInterval, timeout: TimeInterval) throws -> HTTPResponse {
        do {
            return try HTTPClient.post(host: host, port: port, path: path, headers: headers, body: body,
                                       connectTimeout: connectTimeout, readTimeout: timeout)
        } catch let e as NetError {
            throw OnvifClient.map(e, host: host, port: port)
        }
    }
}

/// Talks ONVIF (SOAP over HTTP) to one camera on the local network.
public final class OnvifClient: @unchecked Sendable {
    public let host: String
    public let port: Int
    private let username: String
    private let password: String
    private let timeout: TimeInterval
    private let connectTimeout: TimeInterval
    private let transport: SOAPTransport

    private typealias Endpoint = (port: Int, path: String)

    private let lock = NSLock()
    private var mediaEndpoint: Endpoint?
    private var ptzEndpoint: Endpoint?
    private var clockOffset: TimeInterval = 0
    private var connected = false
    private static let devicePath = "/onvif/device_service"

    public var isConnected: Bool { lock.withLock { connected } }
    public var supportsPtz: Bool { lock.withLock { ptzEndpoint != nil } }

    public init(host: String, port: Int = 2020, username: String, password: String,
                timeout: TimeInterval = 8, connectTimeout: TimeInterval = 4,
                transport: SOAPTransport = SocketSOAPTransport()) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.timeout = timeout
        self.connectTimeout = connectTimeout
        self.transport = transport
    }

    // MARK: API

    /// Syncs to the camera clock and looks up its service addresses.
    public func connect() async throws {
        try await blocking { try self.connectSync() }
    }

    public func deviceInfo() async throws -> DeviceInfo {
        try await blocking {
            let r = try self.parse(self.call(self.device, "<tds:GetDeviceInformation/>"))
            return DeviceInfo(manufacturer: r.text("Manufacturer") ?? "", model: r.text("Model") ?? "",
                              firmware: r.text("FirmwareVersion") ?? "")
        }
    }

    public func profiles() async throws -> [MediaProfile] {
        try await blocking {
            let r = try self.parse(self.call(self.media(), "<trt:GetProfiles/>"))
            return r.all("Profiles").map { p in
                let res = p.first("VideoEncoderConfiguration")?.first("Resolution")
                return MediaProfile(
                    token: p.attribute("token") ?? "",
                    name: p.children("Name").first?.textContent.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                    width: res?.text("Width").flatMap { Int($0) } ?? 0,
                    height: res?.text("Height").flatMap { Int($0) } ?? 0,
                    hasPtz: p.first("PTZConfiguration") != nil)
            }
        }
    }

    public func streamUri(profileToken: String) async throws -> String {
        try await blocking {
            let body = "<trt:GetStreamUri><trt:StreamSetup><tt:Stream>RTP-Unicast</tt:Stream>"
                + "<tt:Transport><tt:Protocol>RTSP</tt:Protocol></tt:Transport></trt:StreamSetup>"
                + "<trt:ProfileToken>\(XML.escape(profileToken))</trt:ProfileToken></trt:GetStreamUri>"
            guard let uri = try self.parse(self.call(self.media(), body)).text("Uri") else {
                throw OnvifError("Camera did not return a stream address")
            }
            return uri
        }
    }

    /// Starts moving. pan/tilt are -1...1 (right and up are positive). Keeps going until `stop`.
    public func continuousMove(profileToken: String, pan: Double, tilt: Double) async throws {
        try await blocking {
            _ = try self.call(try self.ptz(), "<tptz:ContinuousMove><tptz:ProfileToken>\(XML.escape(profileToken))</tptz:ProfileToken>"
                + "<tptz:Velocity><tt:PanTilt x=\"\(Self.fmt(pan))\" y=\"\(Self.fmt(tilt))\"/></tptz:Velocity></tptz:ContinuousMove>")
        }
    }

    public func stop(profileToken: String) async throws {
        try await blocking {
            _ = try self.call(try self.ptz(), "<tptz:Stop><tptz:ProfileToken>\(XML.escape(profileToken))</tptz:ProfileToken>"
                + "<tptz:PanTilt>true</tptz:PanTilt></tptz:Stop>")
        }
    }

    public func presets(profileToken: String) async throws -> [Preset] {
        try await blocking {
            let r = try self.parse(self.call(try self.ptz(), "<tptz:GetPresets><tptz:ProfileToken>\(XML.escape(profileToken))</tptz:ProfileToken></tptz:GetPresets>"))
            return r.all("Preset").map { Preset(token: $0.attribute("token") ?? "", name: $0.text("Name") ?? "") }
        }
    }

    public func gotoPreset(profileToken: String, presetToken: String) async throws {
        try await blocking {
            _ = try self.call(try self.ptz(), "<tptz:GotoPreset><tptz:ProfileToken>\(XML.escape(profileToken))</tptz:ProfileToken>"
                + "<tptz:PresetToken>\(XML.escape(presetToken))</tptz:PresetToken></tptz:GotoPreset>")
        }
    }

    /// Saves the current position. Returns the new preset's token.
    public func setPreset(profileToken: String, name: String) async throws -> String {
        try await blocking {
            let r = try self.parse(self.call(try self.ptz(), "<tptz:SetPreset><tptz:ProfileToken>\(XML.escape(profileToken))</tptz:ProfileToken>"
                + "<tptz:PresetName>\(XML.escape(name))</tptz:PresetName></tptz:SetPreset>"))
            return r.text("PresetToken") ?? ""
        }
    }

    public func removePreset(profileToken: String, presetToken: String) async throws {
        try await blocking {
            _ = try self.call(try self.ptz(), "<tptz:RemovePreset><tptz:ProfileToken>\(XML.escape(profileToken))</tptz:ProfileToken>"
                + "<tptz:PresetToken>\(XML.escape(presetToken))</tptz:PresetToken></tptz:RemovePreset>")
        }
    }

    // MARK: plumbing

    private var device: Endpoint { (port, Self.devicePath) }

    private func blocking<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(with: Result { try work() })
            }
        }
    }

    private func connectSync() throws {
        // Login digests include a timestamp, so use the camera's clock. Some cameras refuse this
        // without a login; that's fine. But if nothing answers at all, stop here.
        do {
            let xml = try post(device, "<tds:GetSystemDateAndTime/>", auth: false)
            if let t = Self.parseCameraTime(xml) {
                lock.withLock { clockOffset = t.timeIntervalSinceNow }
            }
        } catch let e as OnvifError {
            if e.unreachable { throw e }
        }

        let caps = try parse(call(device, "<tds:GetCapabilities><tds:Category>All</tds:Category></tds:GetCapabilities>"))
        let media = caps.first("Media")?.text("XAddr").flatMap(useOurHost)
        let ptz = caps.first("PTZ")?.text("XAddr").flatMap(useOurHost)
        lock.withLock {
            mediaEndpoint = media
            ptzEndpoint = ptz
            connected = true
        }
    }

    private func media() -> Endpoint { lock.withLock { mediaEndpoint } ?? device }

    private func ptz() throws -> Endpoint {
        guard let p = lock.withLock({ ptzEndpoint }) else { throw OnvifError("This camera doesn't support pan/tilt") }
        return p
    }

    private func parse(_ xml: String) throws -> XElement {
        do { return try XML.parse(xml) } catch { throw OnvifError("Camera sent a reply we couldn't read") }
    }

    private static func fmt(_ v: Double) -> String {
        String(format: "%.2f", min(1, max(-1, v.isNaN ? 0 : v)))
    }

    /// Cameras sometimes report addresses with the wrong IP; keep their path, use the IP we reached.
    private func useOurHost(_ xaddr: String) -> Endpoint? {
        let first = xaddr.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").first.map(String.init) ?? ""
        guard let c = URLComponents(string: first), c.host != nil else { return nil }
        let path = c.percentEncodedPath
        return (c.port ?? port, path.isEmpty ? "/" : path)
    }

    private func call(_ ep: Endpoint, _ body: String) throws -> String { try post(ep, body, auth: true) }

    private func post(_ ep: Endpoint, _ body: String, auth: Bool) throws -> String {
        let envelope = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><s:Envelope \(Self.ns)><s:Header>\(auth ? securityHeader() : "")</s:Header><s:Body>\(body)</s:Body></s:Envelope>"
        let payload = Array(envelope.utf8)
        if host.isEmpty || host.unicodeScalars.contains(where: { $0.value <= 0x20 || $0.value == 0x7f }) {
            throw OnvifError("Can't reach camera at \(host):\(port)", unreachable: true)
        }
        var headers = [("Content-Type", "application/soap+xml; charset=utf-8")]
        var retried = false
        while true {
            let resp: HTTPResponse
            do {
                resp = try transport.post(host: host, port: ep.port, path: ep.path, body: payload, headers: headers,
                                          connectTimeout: connectTimeout, timeout: timeout)
            } catch let e as OnvifError {
                throw e
            } catch let e as NetError {
                throw Self.map(e, host: host, port: port)
            } catch {
                throw OnvifError("Can't reach camera at \(host):\(port)", unreachable: true)
            }
            if resp.status == 200 { return String(decoding: resp.body, as: UTF8.self) }
            if resp.status == 401, !retried,
               let challenge = AuthChallenge.parse(resp.headers.all("WWW-Authenticate")),
               case .digest = challenge {
                retried = true
                let authz = Authenticator(credentials: Credentials(username: username, password: password), challenge: challenge)
                    .authorization(method: "POST", uri: ep.path)
                headers = [headers[0], ("Authorization", authz)]
                continue
            }
            throw faultToError(resp.status, String(decoding: resp.body, as: UTF8.self))
        }
    }

    static func map(_ e: NetError, host: String, port: Int) -> OnvifError {
        switch e {
        case .timeout: return OnvifError("Camera at \(host):\(port) didn't answer in time", unreachable: true)
        case .unreachable, .closed, .io: return OnvifError("Can't reach camera at \(host):\(port)", unreachable: true)
        case .protocolError(let why) where why == "invalid host" || why == "invalid path":
            return OnvifError("Can't reach camera at \(host):\(port)", unreachable: true)
        case .protocolError: return OnvifError("Camera sent a reply we couldn't read")
        }
    }

    private func faultToError(_ code: Int, _ body: String) -> OnvifError {
        let fault = try? XML.parse(body)
        let reason = fault?.first("Reason")?.text("Text")
        let subcode = fault?.first("Subcode")?.text("Value") ?? ""
        let authFail = code == 401 || subcode.contains("NotAuthorized")
            || reason?.range(of: "auth", options: .caseInsensitive) != nil
        if authFail { return OnvifError("Wrong username or password") }
        if let reason { return OnvifError("Camera error: \(reason)") }
        return OnvifError("Camera error (HTTP \(code))")
    }

    private func securityHeader() -> String {
        var rng = SystemRandomNumberGenerator()
        let nonce = (0..<16).map { _ in UInt8.random(in: 0...255, using: &rng) }
        let offset = lock.withLock { clockOffset }
        let now = Date().addingTimeInterval(offset)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        let created = formatter.string(from: Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down)))
        let digest = SHA1.hash(nonce + Array(created.utf8) + Array(password.utf8))
        return "<wsse:Security xmlns:wsse=\"\(Self.wsse)\" xmlns:wsu=\"\(Self.wsu)\"><wsse:UsernameToken>"
            + "<wsse:Username>\(XML.escape(username))</wsse:Username>"
            + "<wsse:Password Type=\"\(Self.pwDigest)\">\(Data(digest).base64EncodedString())</wsse:Password>"
            + "<wsse:Nonce EncodingType=\"\(Self.b64Type)\">\(Data(nonce).base64EncodedString())</wsse:Nonce>"
            + "<wsu:Created>\(created)</wsu:Created></wsse:UsernameToken></wsse:Security>"
    }

    private static let ns = "xmlns:s=\"http://www.w3.org/2003/05/soap-envelope\" "
        + "xmlns:tds=\"http://www.onvif.org/ver10/device/wsdl\" "
        + "xmlns:trt=\"http://www.onvif.org/ver10/media/wsdl\" "
        + "xmlns:tptz=\"http://www.onvif.org/ver20/ptz/wsdl\" "
        + "xmlns:tt=\"http://www.onvif.org/ver10/schema\""
    private static let wsse = "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd"
    private static let wsu = "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd"
    private static let pwDigest = "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest"
    private static let b64Type = "http://docs.oasis-open.org/wss/2004/01/oasis-200401-soap-message-security-1.0#Base64Binary"

    /// Reads the UTC time out of a GetSystemDateAndTime response.
    static func parseCameraTime(_ xml: String) -> Date? {
        guard let utc = (try? XML.parse(xml))?.first("UTCDateTime") else { return nil }
        func n(_ tag: String) -> Int? { utc.text(tag).flatMap { Int($0) } }
        guard let y = n("Year"), let mo = n("Month"), let d = n("Day"),
              let h = n("Hour"), let mi = n("Minute"), let s = n("Second"),
              y >= 1970, (1...12).contains(mo), (1...31).contains(d),
              (0...23).contains(h), (0...59).contains(mi), (0...60).contains(s) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(timeZone: cal.timeZone, year: y, month: mo, day: d, hour: h, minute: mi, second: s))
    }
}
