import SwiftUI
import UIKit
import HomeEyeCore

struct LiveView: View {
    let cameraID: String
    @EnvironmentObject private var store: CameraStore
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false

    var body: some View {
        Group {
            if let camera = store.cameras.first(where: { $0.id == cameraID }) {
                LiveScreen(camera: camera, onEdit: { editing = true })
                    // A saved edit (including a password-only one) restarts the stream and
                    // pan/tilt. The Digest pin is left out so pinning doesn't reconnect.
                    .id(LiveIdentity(camera: camera, revision: store.revisions[cameraID] ?? 0))
            } else {
                Color.backdrop
                    .ignoresSafeArea()
                    .onAppear { dismiss() }
            }
        }
        // Outside the identity above, so saving an edit doesn't tear down the sheet mid-dismiss.
        .sheet(isPresented: $editing) {
            EditCameraView(cameraID: cameraID)
        }
    }
}

private struct LiveIdentity: Hashable {
    var camera: Camera
    var revision: Int

    init(camera: Camera, revision: Int) {
        var c = camera
        c.authPinnedDigest = nil
        self.camera = c
        self.revision = revision
    }
}

private struct LiveScreen: View {
    let camera: Camera
    let onEdit: () -> Void

    @EnvironmentObject private var store: CameraStore
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model: LiveModel
    @StateObject private var stream: LiveStream

    @State private var overlayVisible = true
    @State private var interaction = 0
    @State private var askingPresetName = false
    @State private var presetName = ""
    @State private var deleting: Preset?
    @State private var backgrounded = false

    init(camera: Camera, onEdit: @escaping () -> Void) {
        self.camera = camera
        self.onEdit = onEdit
        _model = StateObject(wrappedValue: LiveModel(camera: camera))
        _stream = StateObject(wrappedValue: LiveStream())
    }

    private var fullscreen: Bool { verticalSizeClass == .compact }

    var body: some View {
        ZStack {
            Color.backdrop.ignoresSafeArea()

            VStack(spacing: 0) {
                ZoomableVideo(view: stream.videoView, aspect: stream.aspectRatio, onTap: toggleOverlay)
                    .aspectRatio(stream.aspectRatio, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: fullscreen ? 0 : 16, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        if !fullscreen {
                            StatusPill(status: stream.status)
                                .padding(10)
                                .allowsHitTesting(false)
                        }
                    }
                    .padding(.horizontal, fullscreen ? 0 : 12)
                    .frame(maxWidth: .infinity, maxHeight: fullscreen ? .infinity : nil)

                if !fullscreen {
                    HStack {
                        Spacer()
                        controls
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                    Spacer()
                    if model.ptzReady {
                        JoystickView(onMove: { x, y in model.move(x: x, y: y) },
                                     onRelease: { model.release() })
                        Spacer()
                        Text("Positions")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 8)
                        presetBar(overVideo: false)
                            .padding(.bottom, 20)
                    } else if camera.hasPtz {
                        Text("Connecting pan/tilt…")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            }
            .ignoresSafeArea(.container, edges: fullscreen ? .all : [])

            if fullscreen && overlayVisible {
                overlay
                    .transition(.opacity)
            }
        }
        .environment(\.colorScheme, .dark)
        .toast($model.message)
        .navigationTitle(camera.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(camera.name)
                        .font(.headline)
                        .lineLimit(1)
                    if let modelName = camera.model, !modelName.isEmpty {
                        Text(modelName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Edit", action: onEdit)
                    .accessibilityLabel("Edit camera")
            }
        }
        .toolbar(fullscreen ? .hidden : .visible, for: .navigationBar)
        .toolbarBackground(Color.backdrop, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .statusBarHidden(fullscreen)
        .persistentSystemOverlays(fullscreen ? .hidden : .automatic)
        .alert("Save this position", isPresented: $askingPresetName) {
            TextField("Name", text: $presetName)
            Button("Save") {
                let name = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
                model.savePreset(name: name.isEmpty ? "Position" : name)
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert(
            "Remove “\(deleting?.label ?? "")”?",
            isPresented: Binding(
                get: { deleting != nil },
                set: { if !$0 { deleting = nil } }
            ),
            presenting: deleting
        ) { preset in
            Button("Remove", role: .destructive) { model.deletePreset(preset) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The saved position is deleted from the camera.")
        }
        .onAppear {
            play()
            let password = store.password(for: camera.id)
            Task { await model.connectPTZ(password: password) }
        }
        .onDisappear {
            stream.stop()
            model.close()
        }
        .onChange(of: model.hd) { play() }
        // Like Android ON_STOP: the stream only stops in the background; a brief
        // .inactive (Control Center, alerts) just stops any pan/tilt movement.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                stream.stop()
                model.release()
                backgrounded = true
            case .inactive:
                model.release()
            case .active:
                if backgrounded {
                    backgrounded = false
                    play()
                }
            @unknown default:
                break
            }
        }
        .onChange(of: fullscreen) {
            overlayVisible = true
        }
        // In fullscreen, fade the controls out after a few seconds without interaction.
        .task(id: "\(fullscreen)-\(overlayVisible)-\(interaction)") {
            guard fullscreen && overlayVisible else { return }
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.25)) { overlayVisible = false }
        }
        // Refresh the list thumbnail a few seconds after the picture comes up.
        .task(id: stream.status == .live) {
            guard stream.status == .live else { return }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let image = stream.snapshot() else { return }
            store.saveThumbnail(image, for: camera.id)
        }
    }

    // MARK: Pieces

    private var controls: some View {
        HStack(spacing: 4) {
            if camera.subPath != nil {
                Picker("Quality", selection: $model.hd) {
                    Text("SD").tag(false)
                    Text("HD").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 110)
            }
            if stream.hasAudio {
                iconButton(stream.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                           label: stream.muted ? "Unmute" : "Mute") {
                    stream.muted.toggle()
                }
            }
            iconButton("camera", label: "Take photo") { takeSnapshot() }
            iconButton(fullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                       label: fullscreen ? "Exit fullscreen" : "Fullscreen") {
                toggleFullscreen()
            }
        }
    }

    private func iconButton(_ systemImage: String, label: String,
                            action: @escaping () -> Void) -> some View {
        Button {
            interaction += 1
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.title3)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
    }

    private var overlay: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    toggleFullscreen()
                } label: {
                    Image(systemName: "chevron.backward")
                        .font(.title3.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Exit fullscreen")
                Text(camera.name)
                    .font(.headline)
                    .lineLimit(1)
                StatusPill(status: stream.status)
                Spacer(minLength: 8)
                controls
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background {
                LinearGradient(colors: [Color.black.opacity(0.7), .clear],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
            }

            Spacer(minLength: 0)

            if model.ptzReady {
                HStack(alignment: .bottom, spacing: 24) {
                    presetBar(overVideo: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    JoystickView(size: 148, knob: 56, translucent: true,
                                 onMove: { x, y in
                                     overlayVisible = true
                                     interaction += 1
                                     model.move(x: x, y: y)
                                 },
                                 onRelease: { model.release() })
                }
                .padding(.leading, 16)
                .padding(.trailing, 24)
                .padding(.bottom, 24)
            }
        }
    }

    private func presetBar(overVideo: Bool) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.presets) { preset in
                    Button {
                        interaction += 1
                        model.gotoPreset(preset)
                    } label: {
                        Label(preset.label, systemImage: "bookmark")
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .background(Capsule().fill(Color.black.opacity(overVideo ? 0.55 : 0)))
                    .contextMenu {
                        Button("Remove", role: .destructive) { deleting = preset }
                    }
                }
                Button {
                    interaction += 1
                    presetName = "Position \(model.presets.count + 1)"
                    askingPresetName = true
                } label: {
                    Label("Save Current", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .background(Capsule().fill(Color.black.opacity(overVideo ? 0.55 : 0)))
            }
            .padding(.horizontal, overVideo ? 0 : 16)
        }
    }

    // MARK: Actions

    private func play() {
        let store = store
        let id = camera.id
        // Read once per connect; never kept in view state or identity.
        let password = store.password(for: id)
        stream.play(
            url: camera.rtspURL(hd: model.hd),
            credentials: camera.username.isEmpty
                ? nil : Credentials(username: camera.username, password: password),
            refuseBasic: camera.authPinnedDigest == true,
            onDigestConfirmed: { store.pinDigest(id: id) })
    }

    private func toggleOverlay() {
        guard fullscreen else { return }
        withAnimation(.easeInOut(duration: 0.25)) { overlayVisible.toggle() }
    }

    private func toggleFullscreen() {
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        let orientations: UIInterfaceOrientationMask = fullscreen ? .portrait : .landscapeRight
        scene?.requestGeometryUpdate(
            UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: orientations)) { _ in }
    }

    private func takeSnapshot() {
        guard let image = stream.snapshot() else {
            model.message = "No picture yet"
            return
        }
        Task { @MainActor in
            let saved = await Snapshots.saveToPhotos(image)
            model.message = saved
                ? "Saved to Photos"
                : "Couldn't save the photo. Allow HomeEye to add photos in Settings."
        }
    }
}
