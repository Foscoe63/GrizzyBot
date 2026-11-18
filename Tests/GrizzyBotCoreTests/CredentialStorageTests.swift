import Foundation
import Security
import Testing
@testable import GrizzyBotCore

/// A throwaway store must never write to the person's real login Keychain: every such sign-up used to
/// leave an item behind for good, and each insert got slower as the Keychain grew.
@Suite("Credential storage in tests")
@MainActor
struct CredentialStorageTests {
    private func inKeychain(userId: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.grizzybot.app.credentials",
            kSecAttrAccount as String: "password-\(userId)",
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    @Test("a store with its own data directory keeps credentials in memory, and they still verify")
    func memoryOnly() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("GrizzyBotTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = AppStore(dataDirectory: dir, delayScale: 0.01)
        #expect(AccountCredentialStore.usesInMemoryStorage)
        #expect(store.signUp(name: "T", email: "k\(UUID().uuidString.prefix(6))@b.com", password: "password1") == nil)
        let userId = store.session?.userId ?? ""
        #expect(!userId.isEmpty)
        #expect(AccountCredentialStore.verify(userId: userId, password: "password1"))
        #expect(!AccountCredentialStore.verify(userId: userId, password: "wrong"))
        #expect(!inKeychain(userId: userId))
        AccountCredentialStore.delete(userId: userId)
        #expect(AccountCredentialStore.load(userId: userId) == nil)
    }
}
