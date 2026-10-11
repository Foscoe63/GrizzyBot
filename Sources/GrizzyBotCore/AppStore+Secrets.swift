import Foundation

// Per-bot secrets typed into a native field. Values live in the Keychain-backed secret store and are
// never put in a prompt, a transcript, or an audit record.
extension AppStore {
    public static let secretRequestTool = "secret.request"

    static func botSecretKey(_ botId: String, _ name: String) -> String { "botsecret:\(botId):\(name)" }

    func botSecretValue(botId: String, name: String) -> String? {
        connectionSecrets[Self.botSecretKey(botId, name)]
    }

    /// Names only — safe to show the model so it knows what it can reference.
    public func botSecretNames(botId: String) -> [String] {
        let prefix = "botsecret:\(botId):"
        return connectionSecrets.keys.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }.sorted()
    }

    public func removeBotSecret(botId: String, name: String) {
        connectionSecrets.removeValue(forKey: Self.botSecretKey(botId, name))
        save()
    }

    /// The person typed a value into the secret card. It is stored, the card is settled, and the bot is
    /// told only that the secret exists.
    @discardableResult
    public func supplyBotSecret(botId: String, messageId: String, value: String) -> Bool {
        let key = threadKey(for: botId)
        guard var thread = threads[key],
              let mIdx = thread.messages.firstIndex(where: { $0.id == messageId }) else { return false }
        var name = ""
        for b in thread.messages[mIdx].blocks.indices {
            if case .approval(let tool, let detail, .pending) = thread.messages[mIdx].blocks[b], tool == Self.secretRequestTool {
                name = detail.components(separatedBy: "\n").first ?? ""
                thread.messages[mIdx].blocks[b] = .approval(tool: tool, detail: name, status: .allowed)
            }
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SecretPlaceholders.isValidName(name), !trimmed.isEmpty else { return false }
        // A mistyped reference would only fail later, at the moment it's needed; catch it now.
        if trimmed.hasPrefix("op://"), !OnePasswordCLI.isReference(trimmed) { return false }
        connectionSecrets[Self.botSecretKey(botId, name)] = trimmed
        recordSecretEvent(requested: false, label: name, characterCount: trimmed.count, botId: botId)
        thread.pendingTool = nil
        threads[key] = thread
        save()
        let kind = OnePasswordCLI.isReference(trimmed) ? "a 1Password reference (read only when used)" : "a value in the Keychain"
        send(botId: botId, text: "I saved \(name) as \(kind). Use {{secret:\(name)}} wherever the value belongs. You will never see it.")
        return true
    }
}

extension AppStore {
    public static func botSecretKeyForTesting(_ botId: String, _ name: String) -> String { botSecretKey(botId, name) }
}
