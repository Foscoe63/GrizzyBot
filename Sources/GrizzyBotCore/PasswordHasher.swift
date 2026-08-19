import CommonCrypto
import CryptoKit
import Foundation
import Security

/// PBKDF2-HMAC-SHA256 password storage. Legacy unsalted SHA-256 hex hashes are verified once then upgraded.
public enum PasswordHasher {
    public static let iterations: Int = {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return 2_000
        }
        return 600_000
    }()

    private static let derivedByteCount = 32

    public static func hash(_ password: String) -> String {
        var salt = Data(count: 16)
        _ = salt.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!)
        }
        let derived = pbkdf2(password: password, salt: salt, iterations: iterations)
        return "pbkdf2:\(Self.iterations):\(salt.base64EncodedString()):\(derived.base64EncodedString())"
    }

    public static func verify(_ password: String, stored: String) -> Bool {
        if stored.hasPrefix("pbkdf2:") {
            let parts = stored.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 4,
                  let iterations = Int(parts[1]),
                  let salt = Data(base64Encoded: String(parts[2])),
                  let expected = Data(base64Encoded: String(parts[3]))
            else { return false }
            let derived = pbkdf2(password: password, salt: salt, iterations: iterations)
            return constantTimeEqual(derived, expected)
        }
        let legacy = SHA256.hash(data: Data(password.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return constantTimeEqual(Data(legacy.utf8), Data(stored.utf8))
    }

    public static func needsUpgrade(_ stored: String) -> Bool {
        !stored.hasPrefix("pbkdf2:")
    }

    private static func pbkdf2(
        password: String,
        salt: Data,
        iterations: Int = PasswordHasher.iterations
    ) -> Data {
        var derived = Data(count: derivedByteCount)
        let passwordData = Data(password.utf8)
        let status: Int32 = derived.withUnsafeMutableBytes { derivedBytes in
            salt.withUnsafeBytes { saltBytes in
                passwordData.withUnsafeBytes { passwordBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                        passwordData.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        derivedBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        derivedByteCount
                    )
                }
            }
        }
        guard status == kCCSuccess else { return Data() }
        return derived
    }

    private static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count {
            diff |= a[a.startIndex.advanced(by: i)] ^ b[b.startIndex.advanced(by: i)]
        }
        return diff == 0
    }
}
