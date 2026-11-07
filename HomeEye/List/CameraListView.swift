import SwiftUI
import HomeEyeCore

struct LiveRoute: Hashable {
    let cameraID: String
}

struct EditTarget: Identifiable {
    let id = UUID()
    let cameraID: String?
}

struct CameraListView: View {
    @EnvironmentObject private var store: CameraStore
    @State private var editing: EditTarget?
    @State private var removing: Camera?

    var body: some View {
        List {
            ForEach(store.cameras) { camera in
                NavigationLink(value: LiveRoute(cameraID: camera.id)) {
                    CameraRow(camera: camera)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        removing = camera
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                    Button {
                        editing = EditTarget(cameraID: camera.id)
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .tint(.gray)
                }
                .contextMenu {
                    Button {
                        editing = EditTarget(cameraID: camera.id)
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        removing = camera
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("HomeEye")
        .navigationDestination(for: LiveRoute.self) { route in
            LiveView(cameraID: route.cameraID)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editing = EditTarget(cameraID: nil)
                } label: {
                    Label("Add Camera", systemImage: "plus")
                }
            }
        }
        .sheet(item: $editing) { target in
            EditCameraView(cameraID: target.cameraID)
        }
        .confirmationDialog(
            "Remove \(removing?.name ?? "camera")?",
            isPresented: Binding(
                get: { removing != nil },
                set: { if !$0 { removing = nil } }
            ),
            titleVisibility: .visible,
            presenting: removing
        ) { camera in
            Button("Remove", role: .destructive) {
                store.delete(id: camera.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This removes the camera from HomeEye. Nothing changes on the camera itself.")
        }
        .overlay {
            if store.cameras.isEmpty {
                ContentUnavailableView {
                    Label("No cameras yet", systemImage: "video")
                } description: {
                    Text("Add an ONVIF camera on your Wi-Fi. HomeEye talks to it directly. No cloud, no account.")
                } actions: {
                    Button("Add Camera") {
                        editing = EditTarget(cameraID: nil)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if store.cameras.isEmpty {
                Label("Logins stay encrypted on this iPhone", systemImage: "lock")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)
            }
        }
    }
}

struct CameraRow: View {
    @EnvironmentObject private var store: CameraStore
    let camera: Camera

    private var subtitle: String {
        if let model = camera.model, !model.isEmpty {
            return "\(model) · \(camera.host)"
        }
        return camera.host
    }

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
                .frame(width: 96)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .id(store.thumbnailVersion)

            VStack(alignment: .leading, spacing: 2) {
                Text(camera.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if camera.hasPtz {
                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Pan and tilt")
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image = store.thumbnail(for: camera.id) {
            Color.backdrop
                .overlay {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
                .clipped()
        } else {
            Color.backdrop
                .overlay {
                    Image(systemName: "video")
                        .foregroundStyle(.secondary)
                }
        }
    }
}
