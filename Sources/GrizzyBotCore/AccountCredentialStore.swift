import Foundation
import Security

/// Password hashes live in Keychain — never in users.json on disk.
///
/// A store that was given its own data directory (tests, snapshots, UI-test launches) keeps them in
/// memory instead, so a throwaway account never lands in the person's real login Keychain. Every
/// such sign-up used to leave an item behind for good, and each insert gets slower as the Keychain
/// grows, which stalled the main thread and made unrelated tests time out.
public enum AccountCredentialStore {
    private static let service = "com.grizzybot.app.credentials"

    private final class Memory: @unchecked Sendable {
        private let lock = NSLock()
        private var active = false
        private var hashes: [String: String] = [:]

        var isActive: Bool { lock.lock(); defer { lock.unlock() }; return active }
        func activate() { lock.lock(); active = true; lock.unlock() }
        func set(_ id: String, _ hash: String) { lock.lock(); hashes[id] = hash; lock.unlock() }
        func get(_ id: String) -> String? { lock.lock(); defer { lock.unlock() }; return hashes[id] }
        func remove(_ id: String) { lock.lock(); hashes[id] = nil; lock.unlock() }
    }

    private static let memory = Memory()

    /// From now on this process keeps credentials in memory and never touches the Keychain. One way on
    /// purpose: a process that ever ran a throwaway store must not write to the real one afterwards.
    public static func useInMemoryStorage() { memory.activate() }

    public static var usesInMemoryStorage: Bool { memory.isActive }

    public static func save(userId: String, passwordHash: String) throws {
        if memory.isActive { memory.set(userId, passwordHash); return }
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
        if memory.isActive { return memory.get(userId) }
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
        if memory.isActive { memory.remove(userId); return }
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
