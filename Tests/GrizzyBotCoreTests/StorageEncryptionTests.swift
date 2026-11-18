import CryptoKit
import Foundation
import GrizzyBotCore
import Testing

private final class MemoryKeys: @unchecked Sendable {
    private let lock = NSLock()
    private var key: SymmetricKey?
    var store: StorageEncryption.KeyStore {
        StorageEncryption.KeyStore(
            load: { _ in self.lock.lock(); defer { self.lock.unlock() }; return self.key },
            save: { k, _ in self.lock.lock(); defer { self.lock.unlock() }; self.key = k; return true }
        )
    }
    func lose() { lock.lock(); key = nil; lock.unlock() }
}

@Suite("Storage encryption")
struct StorageEncryptionTests {
    private func tempRoot() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("enc-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("seal and open round-trip, and a wrong key is refused")
    func cipher() throws {
        let key = StorageEncryption.newKey()
        let sealed = try StorageEncryption.seal(Data("hello".utf8), key: key)
        #expect(StorageEncryption.isEncrypted(sealed))
        #expect(try StorageEncryption.open(sealed, key: key) == Data("hello".utf8))
        #expect(throws: StorageEncryption.Failure.self) { try StorageEncryption.open(sealed, key: StorageEncryption.newKey()) }
        #expect(try StorageEncryption.open(Data("plain".utf8), key: key) == Data("plain".utf8), "plaintext always opens")
    }

    @Test("enabling converts files, saves still work, disabling restores them")
    func lifecycle() throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let keys = MemoryKeys()
        var p = Persistence(root: root); p.keyStore = keys.store
        p.saveSession(Session(userId: "u1", name: "Ada", email: "a@b.c"))
        let file = root.appendingPathComponent("session.json")
        let before = try Data(contentsOf: file)
        #expect(!StorageEncryption.isEncrypted(before))

        let result = try StorageEncryption.enable(root: root, keyStore: keys.store)
        #expect(result.converted >= 1)
        #expect(StorageEncryption.isEncrypted(try Data(contentsOf: file)))
        #expect(p.loadSession()?.userId == "u1")
        p.saveSession(Session(userId: "u2", name: "Bo", email: "b@b.c"))
        #expect(StorageEncryption.isEncrypted(try Data(contentsOf: file)), "new writes stay encrypted")
        #expect(p.loadSession()?.userId == "u2")

        try StorageEncryption.disable(root: root, keyStore: keys.store)
        #expect(!StorageEncryption.isEncrypted(try Data(contentsOf: file)))
        #expect(p.loadSession()?.userId == "u2")
    }

    @Test("a lost key reads as nothing, never overwrites, and the recovery key brings it back")
    func recovery() throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let keys = MemoryKeys()
        var p = Persistence(root: root); p.keyStore = keys.store
        p.saveSession(Session(userId: "u1", name: "Ada", email: "a@b.c"))
        let key = StorageEncryption.newKey()
        try StorageEncryption.enable(root: root, keyStore: keys.store, key: key)
        let recovery = StorageEncryption.recoveryString(for: key)

        keys.lose()
        #expect(StorageEncryption.needsRecovery(root: root, keyStore: keys.store))
        #expect(p.loadSession() == nil)
        let onDisk = try Data(contentsOf: root.appendingPathComponent("session.json"))
        p.saveSession(Session(userId: "oops", name: "X", email: "x@b.c"))
        #expect(try Data(contentsOf: root.appendingPathComponent("session.json")) == onDisk, "a save without the key leaves the file alone")

        #expect(!StorageEncryption.recover(root: root, recovery: StorageEncryption.recoveryString(for: StorageEncryption.newKey()), keyStore: keys.store))
        #expect(StorageEncryption.recover(root: root, recovery: recovery, keyStore: keys.store))
        #expect(!StorageEncryption.needsRecovery(root: root, keyStore: keys.store))
        #expect(p.loadSession()?.userId == "u1")
    }

    @Test("a key that can't be stored changes nothing")
    func keychainFails() throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        var p = Persistence(root: root)
        let broken = StorageEncryption.KeyStore(load: { _ in nil }, save: { _, _ in false })
        p.keyStore = broken
        p.saveSession(Session(userId: "u1", name: "Ada", email: "a@b.c"))
        #expect(throws: StorageEncryption.Failure.self) { try StorageEncryption.enable(root: root, keyStore: broken) }
        #expect(!StorageEncryption.marker(in: root).enabled)
        #expect(p.loadSession()?.userId == "u1")
    }
}
