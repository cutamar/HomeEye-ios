import Foundation
import Security
import HomeEyeCore

final class KeychainSecretStore: SecretStore {
    struct KeychainError: Error, LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "Keychain error (\(status))" }
    }

    private let service: String

    init(service: String = "app.homeeye.camera") {
        self.service = service
    }

    private func baseQuery(account: String? = nil) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let account { q[kSecAttrAccount as String] = account }
        return q
    }

    func password(for id: String) -> String? {
        var q = baseQuery(account: id)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func setPassword(_ p: String, for id: String) throws {
        let data = Data(p.utf8)
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemUpdate(baseQuery(account: id) as CFDictionary, update as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var add = baseQuery(account: id)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            add[kSecValueData as String] = data
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            if addStatus != errSecSuccess { throw KeychainError(status: addStatus) }
        default:
            throw KeychainError(status: status)
        }
    }

    func deletePassword(for id: String) {
        SecItemDelete(baseQuery(account: id) as CFDictionary)
    }

    func deleteAll() {
        SecItemDelete(baseQuery() as CFDictionary)
    }
}
