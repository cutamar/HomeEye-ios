import Foundation

public struct Camera: Codable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var host: String
    public var onvifPort: Int
    public var rtspPort: Int
    public var username: String
    public var mainPath: String
    public var subPath: String?
    public var model: String?
    public var hasPtz: Bool
    public var invertPan: Bool
    public var invertTilt: Bool
    /// Set once a stream authenticated with Digest; from then on Basic is refused.
    /// Cleared only when the user edits host, username or password.
    public var authPinnedDigest: Bool?

    public init(
        id: String = UUID().uuidString,
        name: String,
        host: String,
        onvifPort: Int = 2020,
        rtspPort: Int = 554,
        username: String = "",
        mainPath: String = "/stream1",
        subPath: String? = "/stream2",
        model: String? = nil,
        hasPtz: Bool = true,
        invertPan: Bool = false,
        invertTilt: Bool = false,
        authPinnedDigest: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.onvifPort = onvifPort
        self.rtspPort = rtspPort
        self.username = username
        self.mainPath = mainPath
        self.subPath = subPath
        self.model = model
        self.hasPtz = hasPtz
        self.invertPan = invertPan
        self.invertTilt = invertTilt
        self.authPinnedDigest = authPinnedDigest
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, host, onvifPort, rtspPort, username, mainPath, subPath, model
        case hasPtz, invertPan, invertTilt, authPinnedDigest
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        host = try c.decode(String.self, forKey: .host)
        onvifPort = try c.decodeIfPresent(Int.self, forKey: .onvifPort) ?? 2020
        rtspPort = try c.decodeIfPresent(Int.self, forKey: .rtspPort) ?? 554
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        mainPath = try c.decodeIfPresent(String.self, forKey: .mainPath) ?? "/stream1"
        // Absent key -> default; explicit null -> no sub stream.
        subPath = c.contains(.subPath) ? try c.decode(String?.self, forKey: .subPath) : "/stream2"
        model = try c.decodeIfPresent(String.self, forKey: .model)
        hasPtz = try c.decodeIfPresent(Bool.self, forKey: .hasPtz) ?? true
        invertPan = try c.decodeIfPresent(Bool.self, forKey: .invertPan) ?? false
        invertTilt = try c.decodeIfPresent(Bool.self, forKey: .invertTilt) ?? false
        authPinnedDigest = try c.decodeIfPresent(Bool.self, forKey: .authPinnedDigest)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(host, forKey: .host)
        try c.encode(onvifPort, forKey: .onvifPort)
        try c.encode(rtspPort, forKey: .rtspPort)
        try c.encode(username, forKey: .username)
        try c.encode(mainPath, forKey: .mainPath)
        try c.encode(subPath, forKey: .subPath) // explicit null when nil
        try c.encodeIfPresent(model, forKey: .model)
        try c.encode(hasPtz, forKey: .hasPtz)
        try c.encode(invertPan, forKey: .invertPan)
        try c.encode(invertTilt, forKey: .invertTilt)
        try c.encodeIfPresent(authPinnedDigest, forKey: .authPinnedDigest)
    }

    public func streamPath(hd: Bool) -> String {
        if hd { return mainPath }
        return subPath ?? mainPath
    }

    /// RTSP URL without credentials.
    public func rtspURL(hd: Bool) -> String {
        let h = host.contains(":") ? "[\(host)]" : host
        var path = streamPath(hd: hd)
        if !path.hasPrefix("/") { path = "/" + path }
        return "rtsp://\(h):\(rtspPort)\(path)"
    }
}

public enum StreamStatus: Equatable {
    case connecting
    case live
    case retrying(String)
}
