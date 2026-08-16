import Foundation

/// A side effect the store performs when a scripted reply is delivered.
public enum ScriptedAction: Sendable, Equatable {
    case takeover(reason: String)
    case spawnBot(name: String, title: String)
    case deleteBot(name: String)
    case subagent(task: String)
    case destinationWrite(title: String, body: String)
    case writeFile(path: String, content: String)
    case remember(text: String)
}

/// The deterministic reply a bot gives for a prompt.
public struct ScriptedReply: Sendable, Equatable {
    public var text: String
    public var action: ScriptedAction?

    public init(text: String, action: ScriptedAction? = nil) {
        self.text = text
        self.action = action
    }
}

/// Port of rakazo's `inferScript` (packages/adapters/src/scripted-runtime.ts).
/// GrizzyBot runs a local scripted agent so the full product loop works offline:
/// spawn bots, run subagents, remember things, write files, hand over the computer.
public enum ScriptedRuntime {
    public static func reply(to prompt: String) -> ScriptedReply {
        let lower = prompt.lowercased()

        if lower.contains("completed sign-in") || lower.contains("continue without requesting takeover") {
            return ScriptedReply(
                text: "signed in. the session stays in this computer — protected input never hit the thread."
            )
        }

        if lower.contains("take over") || lower.contains("sign in") || lower.contains("login") {
            return ScriptedReply(
                text: "i need you on the screen for a one-time sign-in. handing you the computer.",
                action: .takeover(reason: "Sign in to continue. Protected input stays off the thread.")
            )
        }

        if lower.contains("delete the bot named") || lower.contains("delete the child bot")
            || lower.contains("delete child") {
            let name = namedBot(prompt) ?? "Scout"
            return ScriptedReply(text: "removing that bot permanently.", action: .deleteBot(name: name))
        }

        if lower.contains("spawn a bot") || lower.contains("spawn a child")
            || lower.contains("create a bot named") || lower.contains("create a child bot") {
            let name = namedBot(prompt) ?? "Helper"
            return ScriptedReply(
                text: "creating a bot for that.",
                action: .spawnBot(name: name, title: "\(name) specialist")
            )
        }

        if lower.contains("subagent") || lower.contains("delegate to a helper") {
            return ScriptedReply(
                text: "spinning up a helper for that.",
                action: .subagent(task: prompt)
            )
        }

        if lower.contains("connector") || lower.contains("crm") || lower.contains("destination") {
            return ScriptedReply(
                text: "writing the record through the connected destination.",
                action: .destinationWrite(title: "GrizzyBot result", body: prompt)
            )
        }

        if lower.contains("write") && (lower.contains("file") || lower.contains("home") || lower.contains("note")) {
            let saidPattern = /[sS]ays?\s+(?<said>.+)$/
            var said = prompt
            if let match = prompt.firstMatch(of: saidPattern) {
                var captured = String(match.said)
                while let last = captured.last, last == "." { captured.removeLast() }
                said = captured
            }
            let content = "\(said.trimmingCharacters(in: .whitespacesAndNewlines))\n"
            return ScriptedReply(
                text: "writing that into my home now.",
                action: .writeFile(path: "notes/result.txt", content: content)
            )
        }

        if lower.contains("remember") {
            return ScriptedReply(
                text: "noted — i will keep that in memory.",
                action: .remember(text: prompt)
            )
        }

        return ScriptedReply(
            text: "on it. i will work this in the background and come back with a result.\n\n\(summarize(prompt))",
            action: .writeFile(path: "notes/last-task.md", content: "# Task\n\n\(prompt)\n")
        )
    }

    /// Result text a subagent reports when it finishes.
    public static func subagentResult(for task: String) -> String {
        "done. i handled: \(task.prefix(180))"
    }

    static func summarize(_ prompt: String) -> String {
        "done. i handled: \(prompt.prefix(180))"
    }

    static func namedBot(_ prompt: String) -> String? {
        let pattern = /named\s+(?<bot>[A-Za-z0-9][A-Za-z0-9_-]{0,39})/
        guard let match = prompt.firstMatch(of: pattern) else { return nil }
        return String(match.bot)
    }
}
