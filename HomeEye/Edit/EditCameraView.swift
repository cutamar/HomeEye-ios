import SwiftUI
import HomeEyeCore

/// `cameraID == nil` means "add a new camera".
struct EditCameraView: View {
    let cameraID: String?
    @EnvironmentObject private var store: CameraStore

    var body: some View {
        EditCameraForm(cameraID: cameraID, store: store)
    }
}

private struct EditCameraForm: View {
    @EnvironmentObject private var store: CameraStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: EditCameraModel
    @State private var showPassword = false

    init(cameraID: String?, store: CameraStore) {
        // The autoclosure runs once, so the password is read only when the model is created.
        _model = StateObject(wrappedValue: {
            let existing = cameraID.flatMap { store.camera(id: $0) }
            return EditCameraModel(existing: existing, password: existing.map { store.password(for: $0.id) } ?? "")
        }())
    }

    var body: some View {
        NavigationStack {
            Form {
                if model.isNew { discoverySection }
                cameraSection
                loginSection
                advancedSection
                testSection
            }
            .navigationTitle(model.isNew ? "Add Camera" : "Edit Camera")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { model.save(store: store) { dismiss() } }
                        .disabled(!model.canSave || model.isRunning)
                }
            }
            .onChange(of: model.host) { model.connectionChanged() }
            .onChange(of: model.username) { model.connectionChanged() }
            .onChange(of: model.password) { model.connectionChanged() }
            .onChange(of: model.onvifPort) { model.connectionChanged() }
            .alert("Couldn't connect", isPresented: saveAnywayBinding) {
                Button("Save Anyway") { model.saveAnyway(store: store) { dismiss() } }
                Button("Keep Editing", role: .cancel) {}
            } message: {
                Text("\(model.saveAnywayReason ?? "")\n\nSave anyway? HomeEye will use the usual stream addresses and try again when you open it.")
            }
            .alert("Couldn't save the camera.", isPresented: saveErrorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.saveError ?? "")
            }
        }
    }

    private var saveErrorBinding: Binding<Bool> {
        Binding(
            get: { model.saveError != nil },
            set: { if !$0 { model.saveError = nil } })
    }

    private var saveAnywayBinding: Binding<Bool> {
        Binding(
            get: { model.saveAnywayReason != nil },
            set: { if !$0 { model.saveAnywayReason = nil } })
    }

    private var discoverySection: some View {
        Section {
            Button {
                model.scan()
            } label: {
                if model.scanning {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Looking for cameras…")
                    }
                } else {
                    Label("Find Cameras on Wi-Fi", systemImage: "wifi")
                }
            }
            .disabled(model.scanning)

            ForEach(model.found, id: \.host) { cam in
                Button {
                    model.pick(cam)
                } label: {
                    HStack {
                        Image(systemName: "video")
                        VStack(alignment: .leading) {
                            Text(cam.hardware ?? cam.name ?? "Camera")
                            Text("\(cam.host):\(cam.port)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.host == cam.host {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                .foregroundStyle(.primary)
            }
        } footer: {
            if model.found.isEmpty && model.scanned && !model.scanning {
                Text("No cameras answered. Check the camera is on the same Wi-Fi with ONVIF enabled, or enter its IP below. If you just allowed Local Network access, try again.")
            }
        }
    }

    private var cameraSection: some View {
        Section("Camera") {
            TextField("Name", text: $model.name, prompt: Text("Living room"))
            TextField("IP Address", text: $model.host, prompt: Text("192.168.0.100"))
                .keyboardType(.numbersAndPunctuation)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }

    private var loginSection: some View {
        Section {
            TextField("Username", text: $model.username)
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            HStack {
                Group {
                    if showPassword {
                        TextField("Password", text: $model.password)
                    } else {
                        SecureField("Password", text: $model.password)
                    }
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                Button {
                    showPassword.toggle()
                } label: {
                    Image(systemName: showPassword ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(showPassword ? "Hide password" : "Show password")
            }
        } header: {
            Text("Login")
        } footer: {
            Text("The camera's own account (for Tapo: Camera settings → Advanced → Camera Account), not your cloud login.")
        }
    }

    private var advancedSection: some View {
        Section {
            TextField("ONVIF Port", text: $model.onvifPort)
                .keyboardType(.numberPad)
            Toggle("Reverse Left/Right", isOn: $model.invertPan)
            Toggle("Reverse Up/Down", isOn: $model.invertTilt)
        } header: {
            Text("Advanced")
        } footer: {
            Text("Tapo uses 2020, most others 80. Reverse Up/Down is for ceiling-mounted cameras.")
        }
    }

    private var testSection: some View {
        Section {
            Button {
                model.runTest()
            } label: {
                if model.isRunning {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Connecting…")
                    }
                } else {
                    Text("Test Connection")
                }
            }
            .disabled(!model.canSave || model.isRunning)

            switch model.test {
            case .ok(let r):
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color.liveGreen)
                detail("Camera", [r.info.manufacturer, r.info.model].filter { !$0.isEmpty }.joined(separator: " "))
                detail("Firmware", r.info.firmware)
                detail("HD stream", r.mainResolution)
                detail("SD stream", r.subResolution ?? "")
                detail("Pan / tilt", r.hasPtz ? "Yes" : "No")
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.red)
            case .idle, .running:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private func detail(_ label: String, _ value: String) -> some View {
        if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            LabeledContent(label, value: value)
        }
    }
}
