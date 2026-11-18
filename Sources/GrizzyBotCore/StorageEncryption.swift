import CryptoKit
import Foundation
import Security

/// Opt-in encryption of the JSON files GrizzyBot keeps on disk (AES-256-GCM). Off by default, because an
/// always-on scheme ties every file to one Keychain key, and a lost key (new Mac, re-signed app) would
/// lock the person out of their own data. So:
///  - Files are recognised by a header, not by a setting: a plaintext file always opens, an encrypted one
///    opens when the key is there, and a mix of the two (after an interrupted conversion) just works.
///  - The posture lives in a small plain marker file, since it cannot itself be encrypted.
///  - A recovery key can be exported and later imported, so the data survives losing the Keychain.
public enum StorageEncryption {
    public static let magic = Data("GBENC1\n".utf8)
    public static let markerName = ".storage-encryption.json"

    public static func isEncrypted(_ data: Data) -> Bool { data.starts(with: magic) }

    public enum Failure: Error, Equatable { case keyUnavailable, corrupt }

    public static func seal(_ plain: Data, key: SymmetricKey) throws -> Data {
        guard let combined = try AES.GCM.seal(plain, using: key).combined else { throw Failure.corrupt }
        return magic + combined
    }

    public static func open(_ data: Data, key: SymmetricKey) throws -> Data {
        guard isEncrypted(data) else { return data }
        do { return try AES.GCM.open(AES.GCM.SealedBox(combined: data.dropFirst(magic.count)), using: key) }
        catch { throw Failure.corrupt }
    }

    public static func newKey() -> SymmetricKey { SymmetricKey(size: .bits256) }

    public static func recoveryString(for key: SymmetricKey) -> String {
        key.withUnsafeBytes { Data($0) }.base64EncodedString()
    }

    public static func key(fromRecovery string: String) -> SymmetricKey? {
        guard let data = Data(base64Encoded: string.trimmingCharacters(in: .whitespacesAndNewlines)), data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    // MARK: Posture marker

    public struct Marker: Codable, Equatable {
        public var enabled: Bool
        /// First bytes of SHA-256 of the key, so a wrong or missing key is named, not guessed at.
        public var keyFingerprint: String?
    }

    public static func fingerprint(_ key: SymmetricKey) -> String {
        SHA256.hash(data: key.withUnsafeBytes { Data($0) }).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    public static func marker(in root: URL) -> Marker {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(markerName)),
              let marker = try? JSONDecoder().decode(Marker.self, from: data) else { return Marker(enabled: false, keyFingerprint: nil) }
        return marker
    }

    static func writeMarker(_ marker: Marker, in root: URL) {
        if let data = try? JSONEncoder().encode(marker) { try? data.write(to: root.appendingPathComponent(markerName), options: .atomic) }
    }

    // MARK: Key storage

    /// Where the key lives. The Keychain in the app; a closure pair in tests.
    public struct KeyStore: Sendable {
        public var load: @Sendable (_ root: URL) -> SymmetricKey?
        public var save: @Sendable (_ key: SymmetricKey, _ root: URL) -> Bool

        public init(load: @escaping @Sendable (URL) -> SymmetricKey?, save: @escaping @Sendable (SymmetricKey, URL) -> Bool) {
            self.load = load; self.save = save
        }

        static func account(_ root: URL) -> String { "storage-key-" + SHA256.hash(data: Data(root.path.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined() }

        public static let keychain = KeyStore(
            load: { root in
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.grizzybot.app.storage",
                    kSecAttrAccount as String: account(root), kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
                ]
                var item: CFTypeRef?
                guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data, data.count == 32 else { return nil }
                return SymmetricKey(data: data)
            },
            save: { key, root in
                let data = key.withUnsafeBytes { Data($0) }
                let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.grizzybot.app.storage", kSecAttrAccount as String: account(root)]
                SecItemDelete(query as CFDictionary)
                var add = query
                add[kSecValueData as String] = data
                add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
            }
        )
    }

    // MARK: Converting a folder

    public struct Conversion: Equatable { public var converted: Int; public var skipped: Int }

    /// Only the files that are read and written through `Persistence`: the workspace, users, session,
    /// audit log, governance bundle and snapshots. Files other code reads directly are left alone.
    static func targets(in root: URL) -> [URL] {
        let fm = FileManager.default
        var out = ["users.json", "session.json", "workspace.json", "audit.json", "governance.json"].map { root.appendingPathComponent($0) }
        let names = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        out += names.filter { $0.hasPrefix("user-") && $0.hasSuffix(".json") }.map { root.appendingPathComponent($0) }
        let snaps = root.appendingPathComponent("snapshots")
        out += ((try? fm.contentsOfDirectory(atPath: snaps.path)) ?? []).filter { $0.hasSuffix(".json") }.map { snaps.appendingPathComponent($0) }
        return out.filter { fm.fileExists(atPath: $0.path) }
    }

    /// Turns encryption on: makes (or reuses) a key, stores it, converts every file, then records the posture.
    /// The key is stored and read back before anything is rewritten, so a Keychain failure changes nothing.
    @discardableResult
    public static func enable(root: URL, keyStore: KeyStore = .keychain, key: SymmetricKey? = nil) throws -> Conversion {
        let key = key ?? keyStore.load(root) ?? newKey()
        guard keyStore.save(key, root), let stored = keyStore.load(root), fingerprint(stored) == fingerprint(key) else { throw Failure.keyUnavailable }
        var done = 0, skipped = 0
        for url in targets(in: root) {
            guard let data = try? Data(contentsOf: url) else { skipped += 1; continue }
            if isEncrypted(data) { skipped += 1; continue }
            try seal(data, key: key).write(to: url, options: .atomic)
            done += 1
        }
        writeMarker(Marker(enabled: true, keyFingerprint: fingerprint(key)), in: root)
        return Conversion(converted: done, skipped: skipped)
    }

    /// Turns it off: decrypts every file (needs the key), then records the posture.
    @discardableResult
    public static func disable(root: URL, keyStore: KeyStore = .keychain) throws -> Conversion {
        guard let key = keyStore.load(root) else { throw Failure.keyUnavailable }
        var done = 0, skipped = 0
        for url in targets(in: root) {
            guard let data = try? Data(contentsOf: url), isEncrypted(data) else { skipped += 1; continue }
            try open(data, key: key).write(to: url, options: .atomic)
            done += 1
        }
        writeMarker(Marker(enabled: false, keyFingerprint: nil), in: root)
        return Conversion(converted: done, skipped: skipped)
    }

    /// True when files are encrypted but the key is missing or is the wrong one: the person must import the recovery key.
    public static func needsRecovery(root: URL, keyStore: KeyStore = .keychain) -> Bool {
        let m = marker(in: root)
        guard m.enabled else { return false }
        guard let key = keyStore.load(root) else { return true }
        return m.keyFingerprint.map { $0 != fingerprint(key) } ?? false
    }

    /// Re-stores an exported recovery key, if it is the one this folder was encrypted with.
    public static func recover(root: URL, recovery: String, keyStore: KeyStore = .keychain) -> Bool {
        guard let key = key(fromRecovery: recovery) else { return false }
        let m = marker(in: root)
        if let fp = m.keyFingerprint, fp != fingerprint(key) { return false }
        return keyStore.save(key, root)
    }
}
