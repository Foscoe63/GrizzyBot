import Foundation

/// One remembered fact, as the person sees it: where it lives, whether it is pinned, and whether it
/// was saved after the bot read outside content.
public struct MemoryItem: Identifiable, Sendable, Hashable {
    public var text: String
    public var shared: Bool
    public var pinned: Bool

    public var id: String { "\(shared ? "shared" : "bot")|\(pinned ? "pin" : "fact")|\(text)" }
    public var untrusted: Bool { MemoryLedger.isUntrusted(text) }
    public var display: String { MemoryLedger.plain(text) }
}

extension AppStore {
    /// Pins first, then facts newest-first, for this bot's memory followed by the shared memory.
    public func memoryItems(botId: String) -> [MemoryItem] {
        func items(_ content: String, shared: Bool) -> [MemoryItem] {
            let parsed = MemoryLedger.parse(content)
            return parsed.pin.map { MemoryItem(text: $0, shared: shared, pinned: true) }
                + parsed.facts.reversed().map { MemoryItem(text: $0, shared: shared, pinned: false) }
        }
        return items(botMemory(botId: botId), shared: false) + items(sharedMemory, shared: true)
    }

    private func edit(botId: String, shared: Bool, _ change: (String) -> String?) {
        let current = shared ? sharedMemory : botMemory(botId: botId)
        guard let next = change(current) else { return }
        if shared {
            replaceMemoryDocument(scope: "workspace", botId: nil, path: MemoryFiles.sharedFileName, content: next)
            MemoryFiles.write(MemoryFiles.sharedURL(root: userPersistence.root), content: next)
        } else {
            replaceMemoryDocument(scope: "bot", botId: botId, path: MemoryFiles.botFileName, content: next)
            try? botHome.write(botId: botId, path: MemoryFiles.botFileName, content: next)
        }
        save()
    }

    public func deleteMemoryItem(botId: String, _ item: MemoryItem) {
        edit(botId: botId, shared: item.shared) { content in
            let result = MemoryLedger.remove(content: content, exact: item.text)
            return result.removed ? result.text : nil
        }
    }

    public func trustMemoryItem(botId: String, _ item: MemoryItem) {
        edit(botId: botId, shared: item.shared) { content in
            let result = MemoryLedger.trust(content: content, exact: item.text)
            return result.changed ? result.text : nil
        }
    }

    public func setMemoryItemPinned(botId: String, _ item: MemoryItem, pinned: Bool) {
        edit(botId: botId, shared: item.shared) { content in
            let result = MemoryLedger.setPinned(content: content, exact: item.text, pinned: pinned)
            return result.changed ? result.text : nil
        }
    }
}
