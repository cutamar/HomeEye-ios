import Foundation

public final class CameraRepository {
    public private(set) var cameras: [Camera] = []
    public var hadSavedFile: Bool

    private let directory: URL
    private let secrets: SecretStore
    private var fileURL: URL { directory.appendingPathComponent("cameras.json") }

    public init(directory: URL, secrets: SecretStore) {
        self.directory = directory
        self.secrets = secrets
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("cameras.json")
        hadSavedFile = FileManager.default.fileExists(atPath: url.path)
        if let data = try? Data(contentsOf: url),
           let list = try? JSONDecoder().decode([Camera].self, from: data) {
            cameras = list
        }
    }

    public func camera(id: String) -> Camera? {
        cameras.first { $0.id == id }
    }

    public func upsert(_ c: Camera, password: String) throws {
        let oldPassword = secrets.password(for: c.id)
        try secrets.setPassword(password, for: c.id)
        var updated = cameras
        if let i = updated.firstIndex(where: { $0.id == c.id }) {
            updated[i] = c
        } else {
            updated.append(c)
        }
        do {
            try save(updated)
        } catch {
            if let oldPassword {
                try? secrets.setPassword(oldPassword, for: c.id)
            } else {
                secrets.deletePassword(for: c.id)
            }
            throw error
        }
        cameras = updated
    }

    /// On a failed save, state (list, secret, thumbnail) is left unchanged.
    public func delete(id: String) {
        let updated = cameras.filter { $0.id != id }
        do {
            try save(updated)
        } catch {
            return
        }
        cameras = updated
        secrets.deletePassword(for: id)
        try? FileManager.default.removeItem(at: thumbnailURL(for: id))
    }

    public func password(for id: String) -> String {
        secrets.password(for: id) ?? ""
    }

    public func thumbnailURL(for id: String) -> URL {
        directory.appendingPathComponent("thumbs").appendingPathComponent("\(id).jpg")
    }

    private func save(_ list: [Camera]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(list).write(to: fileURL, options: .atomic)
        hadSavedFile = true
    }
}
