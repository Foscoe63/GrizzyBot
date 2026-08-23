import Foundation
import GrizzyBotCore
import Testing

@Suite("WorkingFolder")
struct WorkingFolderTests {
    @Test("relative paths join the working folder; absolute paths stay absolute")
    func resolvePaths() {
        let root = "/Volumes/Storage/SecondBrain/GrizzyBot-Knowledge/NewsRoom"
        #expect(WorkingFolder.resolve("notes/a.md", workingFolder: root) == "\(root)/notes/a.md")
        #expect(WorkingFolder.resolve("", workingFolder: root) == root)
        #expect(WorkingFolder.resolve("/tmp/x.md", workingFolder: root) == "/tmp/x.md")
        #expect(WorkingFolder.resolve("notes/a.md", workingFolder: nil) == "notes/a.md")
        #expect(WorkingFolder.resolve("MEMORY.md", workingFolder: root) == "MEMORY.md")
        #expect(WorkingFolder.resolve("PLAN.md", workingFolder: root) == "PLAN.md")
        #expect(WorkingFolder.resolve("notes/MEMORY.md", workingFolder: root) == "\(root)/notes/MEMORY.md")
    }

    @Test("contains rejects paths that escape the folder")
    func containsFolder() {
        let root = "/tmp/grizzy-project"
        #expect(WorkingFolder.contains("\(root)/notes/a.md", workingFolder: root))
        #expect(WorkingFolder.contains(root, workingFolder: root))
        #expect(!WorkingFolder.contains("/tmp/other/a.md", workingFolder: root))
        #expect(!WorkingFolder.contains("/tmp/grizzy-project-extra/a.md", workingFolder: root))
        #expect(!WorkingFolder.contains("\(root)/../secret.txt", workingFolder: root))
        #expect(!WorkingFolder.isTrusted("/tmp/x/.ssh/id_rsa", workingFolder: "/tmp/x/.ssh"))
    }

    @Test("prompt names the folder as the project file root")
    func promptNote() {
        let note = WorkingFolder.promptNote("/tmp/proj")
        #expect(note.contains("/tmp/proj"))
        #expect(note.lowercased().contains("relative"))
        #expect(note.lowercased().contains("shell"))
        #expect(WorkingFolder.promptNote(nil).isEmpty)
    }
}

@Suite("BotHome host writes")
struct BotHomeHostWriteTests {
    @Test("writeFlexible can write a host path")
    func writeHostFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grizzy-home-\(UUID().uuidString)", isDirectory: true)
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("grizzy-project-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: project)
        }
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let home = BotHomeStore(root: root)
        let file = project.appendingPathComponent("notes/a.txt")
        try home.writeFlexible(botId: "bot-1", path: file.path, content: "hello\n")
        #expect(try String(contentsOf: file, encoding: .utf8) == "hello\n")
        try home.editFlexible(botId: "bot-1", path: file.path, content: "there\n", mode: .append)
        #expect(try String(contentsOf: file, encoding: .utf8) == "hello\nthere\n")
        let moved = project.appendingPathComponent("notes/b.txt")
        try home.moveFlexible(botId: "bot-1", from: file.path, to: moved.path)
        #expect(FileManager.default.fileExists(atPath: moved.path))
        try home.deleteFlexible(botId: "bot-1", path: moved.path)
        #expect(!FileManager.default.fileExists(atPath: moved.path))
    }
}

@Suite("Working folder agent tools")
@MainActor
struct WorkingFolderStoreTests {
    private func tempStore() -> (AppStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrizzyBotTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = AppStore(dataDirectory: dir, delayScale: 0.01)
        store.pluginClient = AlwaysAllowPlugins()
        return (store, dir)
    }

    private func projectFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("grizzy-work-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test("relative write_file lands in the working folder, not bot home")
    func writeUsesWorkingFolder() async throws {
        let (store, dataDir) = tempStore()
        #expect(store.signUp(name: "A", email: "wf@b.com", password: "password1") == nil)
        let bot = store.createBot(name: "NewsRoom", title: "research")
        let folder = try projectFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        store.updateBot(botId: bot.id, workingFolder: folder.path)
        store.chatCompleter = QueueChatClient([
            ChatCompletionResponse(toolCalls: [LLMToolCall(
                id: "1",
                name: "write_file",
                arguments: "{\"path\":\"notes/brief.md\",\"content\":\"vault-hit\"}"
            )]),
            ChatCompletionResponse(text: "wrote the brief"),
        ])
        store.send(botId: bot.id, text: "write a brief")
        #expect(await store.waitForRunCompletion(botId: bot.id))
        let dest = folder.appendingPathComponent("notes/brief.md")
        #expect(try String(contentsOf: dest, encoding: .utf8) == "vault-hit")
        let nested = dataDir.appendingPathComponent("homes/\(bot.id)/Volumes")
        #expect(!FileManager.default.fileExists(atPath: nested.path))
    }

    @Test("empty list_files lists the working folder without approval")
    func listWorkingFolder() async throws {
        let (store, _) = tempStore()
        #expect(store.signUp(name: "A", email: "wflist@b.com", password: "password1") == nil)
        let bot = store.createBot(name: "NewsRoom", title: "research")
        let folder = try projectFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try "keep\n".write(to: folder.appendingPathComponent("visible.md"), atomically: true, encoding: .utf8)
        store.updateBot(botId: bot.id, workingFolder: folder.path)
        store.chatCompleter = QueueChatClient([
            ChatCompletionResponse(toolCalls: [LLMToolCall(
                id: "1",
                name: "list_files",
                arguments: "{}"
            )]),
            ChatCompletionResponse(text: "listed"),
        ])
        store.send(botId: bot.id, text: "list files")
        #expect(await store.waitForRunCompletion(botId: bot.id))
        #expect(store.threads[bot.id]?.pendingTool == nil)
        let blob = messageBlob(store.threads[bot.id])
        #expect(blob.contains("visible.md"))
    }

    @Test("absolute path outside the working folder still pauses")
    func outsideStillGated() async throws {
        let (store, _) = tempStore()
        #expect(store.signUp(name: "A", email: "wfgate@b.com", password: "password1") == nil)
        let bot = store.createBot(name: "NewsRoom", title: "research")
        let folder = try projectFolder()
        let other = try projectFolder()
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: other)
        }
        let file = other.appendingPathComponent("secret.md")
        try "nope\n".write(to: file, atomically: true, encoding: .utf8)
        store.updateBot(botId: bot.id, workingFolder: folder.path)
        let escaped = file.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        store.chatCompleter = QueueChatClient([
            ChatCompletionResponse(toolCalls: [LLMToolCall(
                id: "1",
                name: "read_file",
                arguments: "{\"path\":\"\(escaped)\"}"
            )]),
        ])
        store.send(botId: bot.id, text: "read that other file")
        #expect(await store.waitForPendingTool(botId: bot.id))
        #expect(store.threads[bot.id]?.pendingTool?.tool == "read_file.host")
    }

    @Test("system prompt describes the working folder as the file root")
    func promptMentionsProject() {
        let prompt = AgentLoop.systemPrompt(
            for: AgentLoopRequest(
                endpoint: ModelEndpoint(provider: "x", model: "y", baseURL: "https://x", apiKey: "k"),
                botName: "NewsRoom",
                prompt: "hi",
                tools: [],
                workingFolderNote: WorkingFolder.promptNote("/tmp/proj")
            )
        )
        #expect(prompt.contains("/tmp/proj"))
        #expect(prompt.contains("working folder"))
        #expect(prompt.contains("shell"))
        #expect(prompt.contains("MCP does not inherit"))
    }

    private func messageBlob(_ thread: ThreadData?) -> String {
        guard let thread else { return "" }
        return thread.messages.flatMap(\.blocks).map { block -> String in
            switch block {
            case .text(let text): return text
            case .card(let lines): return lines.map { "\($0.k) \($0.v)" }.joined(separator: "\n")
            default: return ""
            }
        }.joined(separator: "\n")
    }
}
