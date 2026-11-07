import Foundation

/// What we learn about a camera when testing the connection.
public struct ProbeResult: Equatable {
    public let info: DeviceInfo
    public let rtspPort: Int
    public let mainPath: String
    public let subPath: String?
    public let mainResolution: String
    public let subResolution: String?
    public let hasPtz: Bool

    public init(info: DeviceInfo, rtspPort: Int, mainPath: String, subPath: String?,
                mainResolution: String, subResolution: String?, hasPtz: Bool) {
        self.info = info
        self.rtspPort = rtspPort
        self.mainPath = mainPath
        self.subPath = subPath
        self.mainResolution = mainResolution
        self.subResolution = subResolution
        self.hasPtz = hasPtz
    }
}

public enum CameraProbe {
    /// Logs in over ONVIF and finds the camera's streams. Throws OnvifError with a readable message.
    public static func probe(host: String, onvifPort: Int, username: String, password: String,
                             transport: SOAPTransport = SocketSOAPTransport()) async throws -> ProbeResult {
        let client = OnvifClient(host: host, port: onvifPort, username: username, password: password, transport: transport)
        try await client.connect()
        let info = try await client.deviceInfo()
        // Biggest first (stable); skip MJPEG-only profiles if there are better ones.
        let profiles = try await client.profiles().enumerated()
            .sorted { a, b in
                let sa = a.element.width * a.element.height, sb = b.element.width * b.element.height
                return sa != sb ? sa > sb : a.offset < b.offset
            }.map(\.element)
        let nonJpeg = profiles.filter { $0.name.range(of: "jpeg", options: .caseInsensitive) == nil }
        let video = nonJpeg.isEmpty ? profiles : nonJpeg
        guard let main = video.first else { throw OnvifError("Camera did not return a stream address") }
        let sub = video.count > 1 ? video[1] : nil
        let mainParts = try parts(try await client.streamUri(profileToken: main.token))
        var subPath: String?
        if let sub {
            subPath = try parts(try await client.streamUri(profileToken: sub.token)).path
        }
        return ProbeResult(
            info: info,
            rtspPort: mainParts.port ?? 554,
            mainPath: mainParts.path,
            subPath: subPath,
            mainResolution: "\(main.width)\u{D7}\(main.height)",
            subResolution: sub.map { "\($0.width)\u{D7}\($0.height)" },
            hasPtz: client.supportsPtz && profiles.contains { $0.hasPtz })
    }

    private static func parts(_ uri: String) throws -> (port: Int?, path: String) {
        guard let c = URLComponents(string: uri.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw OnvifError("Camera did not return a stream address")
        }
        let path = c.percentEncodedPath.isEmpty ? "/" : c.percentEncodedPath
        return (c.port, path + (c.percentEncodedQuery.map { "?\($0)" } ?? ""))
    }
}

extension Camera {
    public func applying(_ p: ProbeResult) -> Camera {
        var c = self
        c.rtspPort = p.rtspPort
        c.mainPath = p.mainPath
        c.subPath = p.subPath
        c.model = p.info.model.isEmpty ? nil : p.info.model
        c.hasPtz = p.hasPtz
        return c
    }
}

public final class OnvifPTZ: PTZControlling {
    private let client: OnvifClient
    private let profileToken: String

    public init(client: OnvifClient, profileToken: String) {
        self.client = client
        self.profileToken = profileToken
    }

    public func continuousMove(pan: Double, tilt: Double) async throws {
        try await client.continuousMove(profileToken: profileToken, pan: pan, tilt: tilt)
    }

    public func stop() async throws {
        try await client.stop(profileToken: profileToken)
    }
}
