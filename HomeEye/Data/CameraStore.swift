import Foundation
import Combine
import UIKit
import HomeEyeCore

@MainActor
final class CameraStore: ObservableObject {
    @Published private(set) var cameras: [Camera] = []
    @Published private(set) var thumbnailVersion = 0
    /// Bumped per camera on every successful save, so open screens restart even when only
    /// the password changed. `pinDigest` deliberately doesn't bump it.
    @Published private(set) var revisions: [String: Int] = [:]

    private let repo: CameraRepository

    init() {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("HomeEye")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var excluded = dir
        try? excluded.setResourceValues(values)

        let secrets = KeychainSecretStore()
        let repo = CameraRepository(directory: dir, secrets: secrets)
        // Keychain items survive an uninstall; clear orphans on a fresh install.
        if !repo.hadSavedFile { secrets.deleteAll() }
        self.repo = repo
        self.cameras = repo.cameras
    }

    func camera(id: String) -> Camera? {
        repo.camera(id: id)
    }

    func password(for id: String) -> String {
        repo.password(for: id)
    }

    func save(_ camera: Camera, password: String) throws {
        defer { cameras = repo.cameras }
        var camera = camera
        // Editing host or credentials drops the Digest pin; nothing else ever does.
        if let old = repo.camera(id: camera.id),
           old.host != camera.host || old.username != camera.username
            || repo.password(for: camera.id) != password {
            camera.authPinnedDigest = nil
        }
        try repo.upsert(camera, password: password)
        revisions[camera.id, default: 0] += 1
    }

    /// Remembers that this camera authenticated with Digest so Basic is refused from now on.
    func pinDigest(id: String) {
        guard var camera = repo.camera(id: id), camera.authPinnedDigest != true else { return }
        camera.authPinnedDigest = true
        try? repo.upsert(camera, password: repo.password(for: id))
        cameras = repo.cameras
    }

    /// Repository delete is non-throwing and leaves state unchanged if saving fails,
    /// so the refreshed list simply reflects whatever actually happened.
    func delete(id: String) {
        repo.delete(id: id)
        cameras = repo.cameras
        thumbnailVersion += 1
    }

    func thumbnailURL(for id: String) -> URL {
        repo.thumbnailURL(for: id)
    }

    func thumbnail(for id: String) -> UIImage? {
        UIImage(contentsOfFile: repo.thumbnailURL(for: id).path)
    }

    func saveThumbnail(_ image: UIImage, for id: String) {
        guard camera(id: id) != nil, image.size.width > 0 else { return }
        let url = repo.thumbnailURL(for: id)
        DispatchQueue.global(qos: .utility).async {
            let targetWidth: CGFloat = 640
            let size = CGSize(width: targetWidth,
                              height: (image.size.height * targetWidth / image.size.width).rounded())
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let scaled = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
            guard let data = scaled.jpegData(compressionQuality: 0.8) else { return }
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard (try? data.write(to: url, options: .atomic)) != nil else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.camera(id: id) != nil {
                    self.thumbnailVersion += 1
                } else {
                    // Camera was deleted while writing; remove the orphan file.
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
    }
}
