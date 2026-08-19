import Foundation
import Security

/// Password hashes live in Keychain — never in users.json on disk.
public enum AccountCredentialStore {
    private static let service = "com.grizzybot.app.credentials"

    public static func save(userId: String, passwordHash: String) throws {
        let data = Data(passwordHash.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(userId),
        ]
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecSuccess { return }
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw AccountCredentialStoreError.keychain(addStatus)
            }
            return
        }
        throw AccountCredentialStoreError.keychain(status)
    }

    public static func load(userId: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(userId),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func delete(userId: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(userId),
        ]
        SecItemDelete(query as CFDictionary)
    }

    public static func verify(userId: String, password: String) -> Bool {
        guard let stored = load(userId: userId) else { return false }
        return PasswordHasher.verify(password, stored: stored)
    }

    private static func account(_ userId: String) -> String { "password-\(userId)" }
}

public enum AccountCredentialStoreError: Error, Sendable {
    case keychain(OSStatus)
}
