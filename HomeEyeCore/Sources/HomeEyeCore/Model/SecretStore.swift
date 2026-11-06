import Foundation

public protocol SecretStore: AnyObject {
    func password(for id: String) -> String?
    func setPassword(_ p: String, for id: String) throws
    func deletePassword(for id: String)
    func deleteAll()
}

public final class InMemorySecretStore: SecretStore {
    private var passwords: [String: String] = [:]
    private let lock = NSLock()

    public init() {}

    public func password(for id: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return passwords[id]
    }

    public func setPassword(_ p: String, for id: String) throws {
        lock.lock(); defer { lock.unlock() }
        passwords[id] = p
    }

    public func deletePassword(for id: String) {
        lock.lock(); defer { lock.unlock() }
        passwords[id] = nil
    }

    public func deleteAll() {
        lock.lock(); defer { lock.unlock() }
        passwords.removeAll()
    }
}
