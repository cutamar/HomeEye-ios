import Combine
import Foundation
import HomeEyeCore

/// Pan/tilt and preset state for the live screen. The stream itself lives in `LiveStream`.
@MainActor
final class LiveModel: ObservableObject {
    let camera: Camera

    @Published var hd = false
    @Published private(set) var ptzReady = false
    @Published private(set) var presets: [Preset] = []
    /// One-off message for the toast.
    @Published var message: String?

    private var client: OnvifClient?
    private var token: String?
    private var mover: PTZMover?
    private var connecting = false

    init(camera: Camera) {
        self.camera = camera
    }

    /// The password is read by the caller at call time, never stored on the model.
    func connectPTZ(password: String) async {
        guard camera.hasPtz, !connecting, client == nil else { return }
        connecting = true
        defer { connecting = false }
        do {
            let c = OnvifClient(host: camera.host, port: camera.onvifPort,
                                username: camera.username, password: password)
            try await c.connect()
            guard c.supportsPtz, let first = try await c.profiles().first else { return }
            let t = first.token
            client = c
            token = t
            // Weak: the mover is owned by this model.
            mover = PTZMover(controller: OnvifPTZ(client: c, profileToken: t)) { [weak self] m in
                let model = self
                Task { @MainActor in model?.message = m }
            }
            ptzReady = true
            presets = (try? await c.presets(profileToken: t)) ?? []
        } catch {
            message = "Pan/tilt unavailable: \(error.localizedDescription)"
        }
    }

    /// x/y in -1...1 from the joystick (right/up positive).
    func move(x: Double, y: Double) {
        guard let mover else { return }
        if let cmd = JoystickMath.command(x: x, y: y, invertPan: camera.invertPan, invertTilt: camera.invertTilt) {
            mover.move(pan: cmd.pan, tilt: cmd.tilt)
        } else {
            mover.stop()
        }
    }

    func release() {
        mover?.stop()
    }

    func gotoPreset(_ p: Preset) {
        ptzCall("Couldn't move to \(p.label)") { c, t in
            try await c.gotoPreset(profileToken: t, presetToken: p.token)
        }
    }

    func savePreset(name: String) {
        ptzCall("Couldn't save position") { [weak self] c, t in
            _ = try await c.setPreset(profileToken: t, name: name)
            let list = try await c.presets(profileToken: t)
            self?.presets = list
            self?.message = "Saved \"\(name)\""
        }
    }

    func deletePreset(_ p: Preset) {
        ptzCall("Couldn't remove \(p.label)") { [weak self] c, t in
            try await c.removePreset(profileToken: t, presetToken: p.token)
            let list = try await c.presets(profileToken: t)
            self?.presets = list
        }
    }

    /// Never leave the camera moving when the screen closes.
    func close() {
        mover?.stop()
    }

    private func ptzCall(_ failure: String, _ work: @escaping @MainActor (OnvifClient, String) async throws -> Void) {
        guard let c = client, let t = token else { return }
        Task { @MainActor [weak self] in
            do {
                try await work(c, t)
            } catch {
                self?.message = "\(failure): \(error.localizedDescription)"
            }
        }
    }
}

extension Preset {
    /// Display name; cameras may return presets without a name.
    var label: String { name.isEmpty ? "Position \(token)" : name }
}
