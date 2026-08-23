import Foundation

/// Session checklist + clarify/complete helpers for long agent loops (Osaurus-inspired).
public struct AgentTodoList: Sendable, Equatable {
    public var markdown: String
    public var totalCount: Int
    public var doneCount: Int

    public init(markdown: String, totalCount: Int, doneCount: Int) {
        self.markdown = markdown
        self.totalCount = totalCount
        self.doneCount = doneCount
    }

    public static func parse(_ markdown: String) -> AgentTodoList {
        let lines = markdown.split(whereSeparator: \.isNewline).map(String.init)
        var total = 0
        var done = 0
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.range(of: #"^-\s*\[[xX]\]"#, options: .regularExpression) != nil {
                total += 1
                done += 1
            } else if trimmed.range(of: #"^-\s*\[\s*\]"#, options: .regularExpression) != nil {
                total += 1
            }
        }
        return AgentTodoList(markdown: markdown, totalCount: total, doneCount: done)
    }
}

public actor AgentTodoStore {
    public static let shared = AgentTodoStore()
    private var byThread: [String: AgentTodoList] = [:]
    private var touchedThisRun: Set<String> = []

    public func setTodo(markdown: String, for threadKey: String) -> AgentTodoList {
        let parsed = AgentTodoList.parse(markdown)
        byThread[threadKey] = parsed
        touchedThisRun.insert(threadKey)
        return parsed
    }

    public func todo(for threadKey: String) -> AgentTodoList? {
        byThread[threadKey]
    }

    public func markRunTouched(_ threadKey: String) {
        touchedThisRun.insert(threadKey)
    }

    public func clearRun(_ threadKey: String) {
        touchedThisRun.remove(threadKey)
    }

    public func wasTouchedThisRun(_ threadKey: String) -> Bool {
        touchedThisRun.contains(threadKey)
    }
}

public enum AgentSessionTools {
    public static func handleTodo(markdown: String, threadKey: String) async -> AgentToolCallResult {
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return AgentToolCallResult(output: "`markdown` must be a non-empty checklist with `- [ ]` / `- [x]` items.")
        }
        let parsed = AgentTodoList.parse(trimmed)
        guard parsed.totalCount > 0 else {
            return AgentToolCallResult(
                output: "No checklist items found. Every item must start with `- [ ]` or `- [x]`."
            )
        }
        let stored = await AgentTodoStore.shared.setTodo(markdown: trimmed, for: threadKey)
        return AgentToolCallResult(
            output: "Todo updated (\(stored.doneCount)/\(stored.totalCount) done).\n\(stored.markdown)",
            blocks: [.card(lines: [
                CardLine(k: "todo", v: "\(stored.doneCount)/\(stored.totalCount)"),
            ])]
        )
    }

    public static func handleComplete(summary: String, threadKey: String) async -> AgentToolCallResult {
        let todo = await AgentTodoStore.shared.todo(for: threadKey)
        await AgentTodoStore.shared.clearRun(threadKey)
        let pending = (todo.map { $0.totalCount - $0.doneCount }) ?? 0
        let text = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        var out = text.isEmpty ? "Task complete." : text
        if pending > 0 {
            out += "\n(Note: \(pending) checklist item(s) still unchecked.)"
        }
        return AgentToolCallResult(
            output: out,
            blocks: [.card(lines: [CardLine(k: "complete", v: out)])],
            endTurn: true
        )
    }

    public static func handleClarify(question: String) -> AgentToolCallResult {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            return AgentToolCallResult(output: "`question` is required.")
        }
        return AgentToolCallResult(
            output: "Waiting for your answer.",
            blocks: [.ask(text: q, detail: nil)],
            pause: .waitingInput
        )
    }
}

/// Resolves relative paths under a bot working folder when set.
/// `MEMORY.md` and `PLAN.md` with no slash stay in the bot home.
public enum WorkingFolder {
    private static let homeOnlyNames: Set<String> = ["MEMORY.md", "PLAN.md"]

    public static func resolve(_ path: String, workingFolder: String?) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if homeOnlyNames.contains(trimmed) { return trimmed }
        guard let folder = workingFolder?.trimmingCharacters(in: .whitespacesAndNewlines), !folder.isEmpty else {
            return trimmed
        }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            return BotHomeStore.expandPath(trimmed)
        }
        let root = BotHomeStore.expandPath(folder)
        if trimmed.isEmpty { return root }
        return (root as NSString).appendingPathComponent(trimmed)
    }

    public static func contains(_ path: String, workingFolder: String?) -> Bool {
        guard let folder = workingFolder?.trimmingCharacters(in: .whitespacesAndNewlines), !folder.isEmpty else {
            return false
        }
        let root = standardized(BotHomeStore.expandPath(folder))
        let target = standardized(BotHomeStore.expandPath(path))
        return target == root || target.hasPrefix(root + "/")
    }

    public static func isTrusted(_ path: String, workingFolder: String?) -> Bool {
        contains(path, workingFolder: workingFolder) && !BotHomeStore.isDeniedHostPath(path)
    }

    public static func promptNote(_ workingFolder: String?) -> String {
        guard let folder = workingFolder?.trimmingCharacters(in: .whitespacesAndNewlines), !folder.isEmpty else {
            return ""
        }
        let root = BotHomeStore.expandPath(folder)
        return """
        Working folder for this bot: \(root). Relative read_file, write_file, edit_file, move_file, delete_file, and list_files use this folder (empty list_files lists it). Writes here go to that folder on disk without extra approval. Shell ~ stays the bot home. MCP does not inherit this folder — pass absolute paths. MEMORY.md and PLAN.md (no slash) stay in Home path.
        """
    }

    private static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
