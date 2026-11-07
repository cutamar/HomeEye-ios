import Foundation
import HomeEyeCore

enum TestState: Equatable {
    case idle
    case running
    case ok(ProbeResult)
    case failed(String)
}

@MainActor
final class EditCameraModel: ObservableObject {
    private let existing: Camera?
    /// Stable id for a new camera, so repeated saves update one record.
    private let newID = UUID().uuidString
    private var isSaving = false
    let isNew: Bool

    @Published var name: String
    @Published var host: String
    @Published var username: String
    @Published var password: String
    @Published var onvifPort: String {
        didSet {
            let digits = onvifPort.filter { $0.isASCII && $0.isNumber }
            if digits != onvifPort { onvifPort = digits }
        }
    }
    @Published var invertPan: Bool
    @Published var invertTilt: Bool

    @Published private(set) var test: TestState = .idle
    @Published private(set) var scanning = false
    @Published private(set) var scanned = false
    @Published private(set) var found: [DiscoveredCamera] = []
    /// Set when saving failed the connection test; the view asks "save anyway?".
    @Published var saveAnywayReason: String?
    /// Set when the camera couldn't be written to storage.
    @Published var saveError: String?

    private var testTask: Task<Void, Never>?

    init(existing: Camera?, password: String) {
        self.existing = existing
        self.isNew = existing == nil
        self.name = existing?.name ?? ""
        self.host = existing?.host ?? ""
        self.username = existing?.username ?? ""
        self.password = password
        self.onvifPort = String(existing?.onvifPort ?? 2020)
        self.invertPan = existing?.invertPan ?? false
        self.invertTilt = existing?.invertTilt ?? false
    }

    var canSave: Bool {
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && Int(onvifPort) != nil
    }

    var isRunning: Bool { test == .running }

    /// Any edit to connection fields makes an earlier test result stale.
    func connectionChanged() {
        if test != .running { test = .idle }
    }

    func scan() {
        if scanning { return }
        scanning = true
        found = []
        Task { [weak self] in
            let all = await Discovery.scan { cam in
                // Called from a background thread.
                Task { @MainActor [weak self] in self?.add(cam) }
            }
            guard let self else { return }
            for cam in all { self.add(cam) }
            self.scanning = false
            self.scanned = true
        }
    }

    private func add(_ cam: DiscoveredCamera) {
        if !found.contains(where: { $0.host == cam.host }) { found.append(cam) }
    }

    func pick(_ cam: DiscoveredCamera) {
        host = cam.host
        onvifPort = String(cam.port)
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            name = cam.hardware ?? cam.name ?? ""
        }
        connectionChanged()
    }

    func runTest() {
        startTest(onSuccess: { _ in }, onFailure: { _ in })
    }

    /// Saves after a successful test. If the test fails, asks whether to save anyway.
    func save(store: CameraStore, onDone: @escaping () -> Void) {
        if isSaving { return }
        isSaving = true
        if case .ok(let result) = test {
            finish(probe: result, store: store, onDone: onDone)
            return
        }
        startTest(
            onSuccess: { [weak self] result in
                self?.finish(probe: result, store: store, onDone: onDone)
            },
            onFailure: { [weak self] reason in
                self?.isSaving = false
                self?.saveAnywayReason = reason
            })
    }

    func saveAnyway(store: CameraStore, onDone: @escaping () -> Void) {
        saveAnywayReason = nil
        if isSaving { return }
        isSaving = true
        finish(probe: nil, store: store, onDone: onDone)
    }

    private func finish(probe: ProbeResult?, store: CameraStore, onDone: () -> Void) {
        if self.store(probe: probe, in: store) {
            onDone()
        } else {
            isSaving = false
        }
    }

    private func startTest(onSuccess: @escaping (ProbeResult) -> Void, onFailure: @escaping (String) -> Void) {
        guard let port = Int(onvifPort) else { return }
        testTask?.cancel()
        test = .running
        let host = self.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let pass = password
        testTask = Task { [weak self] in
            do {
                let result = try await CameraProbe.probe(host: host, onvifPort: port, username: user, password: pass)
                if Task.isCancelled { return }
                self?.test = .ok(result)
                onSuccess(result)
            } catch {
                if Task.isCancelled { return }
                let message = (error as? OnvifError)?.message ?? error.localizedDescription
                self?.test = .failed(message)
                onFailure(message)
            }
        }
    }

    /// Returns false (and shows the error) if the camera couldn't be saved.
    private func store(probe: ProbeResult?, in store: CameraStore) -> Bool {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var cam = existing ?? Camera(id: newID, name: "", host: "", username: "")
        if !trimmedName.isEmpty {
            cam.name = trimmedName
        } else if let model = probe?.info.model, !model.isEmpty {
            cam.name = model
        } else {
            cam.name = trimmedHost
        }
        cam.host = trimmedHost
        cam.onvifPort = Int(onvifPort) ?? 2020
        cam.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        cam.invertPan = invertPan
        cam.invertTilt = invertTilt
        if let probe { cam = cam.applying(probe) }
        do {
            try store.save(cam, password: password)
            return true
        } catch {
            saveError = error.localizedDescription
            return false
        }
    }
}
