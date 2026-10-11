import Foundation

/// 1Password through its own command-line tool. A saved secret can be an `op://vault/item/field`
/// reference instead of a value: GrizzyBot asks `op` for the real value only at the moment of use
/// (1Password prompts you with Touch ID), keeps nothing, and scrubs it from the result.
public protocol SecretReferenceReading: Sendable {
    func read(_ reference: String) async throws -> String
}

public enum OnePasswordError: Error, LocalizedError, Equatable {
    case notInstalled
    case failed(String)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .notInstalled: return "The 1Password command-line tool (op) isn't installed. Install it with `brew install 1password-cli` and turn on “Integrate with 1Password CLI” in 1Password’s settings."
        case .failed(let why): return "1Password said: \(why)"
        case .timedOut: return "1Password didn't answer in time — approve the prompt (Touch ID) and try again."
        }
    }
}

public struct OnePasswordCLI: SecretReferenceReading {
    public init() {}

    public static func isReference(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("op://") else { return false }
        let parts = t.dropFirst(5).split(separator: "/", omittingEmptySubsequences: true)
        return parts.count >= 3 && !t.contains(" ") && !t.contains("\n")
    }

    static func locate() -> String? {
        ["/opt/homebrew/bin/op", "/usr/local/bin/op", "/usr/bin/op"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public func read(_ reference: String) async throws -> String {
        guard Self.isReference(reference) else { throw OnePasswordError.failed("not an op:// reference") }
        guard let path = Self.locate() else { throw OnePasswordError.notInstalled }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = ["read", "--no-newline", reference.trimmingCharacters(in: .whitespacesAndNewlines)]
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                do { try process.run() } catch {
                    continuation.resume(throwing: OnePasswordError.failed(error.localizedDescription))
                    return
                }
                let deadline = DispatchTime.now() + 45
                let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: deadline, execute: killer)
                let data = out.fileHandleForReading.readDataToEndOfFile()
                let errData = err.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                killer.cancel()
                if process.terminationReason == .uncaughtSignal {
                    continuation.resume(throwing: OnePasswordError.timedOut)
                } else if process.terminationStatus == 0 {
                    continuation.resume(returning: String(decoding: data, as: UTF8.self))
                } else {
                    let message = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: OnePasswordError.failed(String(message.prefix(300))))
                }
            }
        }
    }
}
