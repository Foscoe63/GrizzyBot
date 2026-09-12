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
        let runNote = WorkingFolder.promptNote("/tmp/proj", scopedToRun: true)
        #expect(runNote.contains("this run"))
        #expect(runNote.contains("every bot"))
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
        // Real FSEvents stay off in tests. `saveFolderWatcher` reconfigures the
        // process-wide `FolderWatcherService.shared` and, when enabled, starts
        // watching real directories — so parallel tests repoint one another's
        // service and fire events into throwaway stores. Watcher behaviour is
        // driven through the explicit seams (`runFolderWatcherNow`,
        // `handleFolderWatcherEvent`) instead, which call the same code path
        // without the shared singleton.
        store.appConfig.enableFolderWatchers = false
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

    @Test("folder watcher run lists the watch path even when the bot has no working folder")
    func watcherRunUsesWatchPathWithoutBotFolder() async throws {
        let (store, _) = tempStore()
        #expect(store.signUp(name: "A", email: "wfwatch@b.com", password: "password1") == nil)
        let bot = store.createBot(name: "Scout", title: "ops")
        let watchFolder = try projectFolder()
        defer { try? FileManager.default.removeItem(at: watchFolder) }
        try "from-watch\n".write(
            to: watchFolder.appendingPathComponent("watch-me.md"),
            atomically: true,
            encoding: .utf8
        )
        let before = store.bots.first(where: { $0.id == bot.id })!
        #expect(store.effectiveWorkingFolder(for: before) == nil)

        try saveWatcher(store: store, name: "Folder-Organize", path: watchFolder.path, botId: bot.id)
        let client = listFilesClient()
        store.chatCompleter = client
        let result = store.runFolderWatcherNow(id: store.folderWatchers.first { $0.botId == bot.id }!.id)
        #expect(result.contains("Triggered"))
        let during = store.bots.first(where: { $0.id == bot.id })!
        #expect(store.effectiveWorkingFolder(for: during) == watchFolder.path)
        #expect(await store.waitForRunCompletion(botId: bot.id))
        let after = store.bots.first(where: { $0.id == bot.id })!
        #expect(store.effectiveWorkingFolder(for: after) == nil)
        let blob = messageBlob(store.threads[bot.id])
        #expect(blob.contains("watch-me.md"))
        let system = client.requests.first?.messages.first { $0.role == "system" }?.content ?? ""
        #expect(system.contains("this run"))
        #expect(system.contains(watchFolder.path))
        #expect(!system.contains("Matched skills for this turn"))
    }

    @Test("folder watcher pins the watch path for every assigned bot")
    func watcherRunPinsEveryBot() async throws {
        let (store, _) = tempStore()
        #expect(store.signUp(name: "A", email: "wfmulti@b.com", password: "password1") == nil)
        let operatorBot = store.createBot(from: BotTemplates.desktopOperator)
        let researcher = store.createBot(from: BotTemplates.researcher)
        let operatorVault = try projectFolder()
        let researcherVault = try projectFolder()
        let operatorWatch = try projectFolder()
        let researcherWatch = try projectFolder()
        defer {
            try? FileManager.default.removeItem(at: operatorVault)
            try? FileManager.default.removeItem(at: researcherVault)
            try? FileManager.default.removeItem(at: operatorWatch)
            try? FileManager.default.removeItem(at: researcherWatch)
        }
        try "operator-vault\n".write(
            to: operatorVault.appendingPathComponent("operator-vault.md"),
            atomically: true,
            encoding: .utf8
        )
        try "researcher-vault\n".write(
            to: researcherVault.appendingPathComponent("researcher-vault.md"),
            atomically: true,
            encoding: .utf8
        )
        try "operator-watch\n".write(
            to: operatorWatch.appendingPathComponent("operator-watch.md"),
            atomically: true,
            encoding: .utf8
        )
        try "researcher-watch\n".write(
            to: researcherWatch.appendingPathComponent("researcher-watch.md"),
            atomically: true,
            encoding: .utf8
        )
        store.updateBot(botId: operatorBot.id, workingFolder: operatorVault.path)
        store.updateBot(botId: researcher.id, workingFolder: researcherVault.path)

        try saveWatcher(store: store, name: "Operator-Inbox", path: operatorWatch.path, botId: operatorBot.id)
        try saveWatcher(store: store, name: "Research-Inbox", path: researcherWatch.path, botId: researcher.id)

        store.chatCompleter = listFilesClient()
        _ = store.runFolderWatcherNow(id: store.folderWatchers.first { $0.botId == operatorBot.id }!.id)
        #expect(await store.waitForRunCompletion(botId: operatorBot.id))
        let operatorBlob = messageBlob(store.threads[operatorBot.id])
        #expect(operatorBlob.contains("operator-watch.md"))
        #expect(!operatorBlob.contains("operator-vault.md"))
        #expect(store.effectiveWorkingFolder(for: store.bots.first { $0.id == operatorBot.id }!) == operatorVault.path)

        store.chatCompleter = listFilesClient()
        _ = store.runFolderWatcherNow(id: store.folderWatchers.first { $0.botId == researcher.id }!.id)
        #expect(await store.waitForRunCompletion(botId: researcher.id))
        let researcherBlob = messageBlob(store.threads[researcher.id])
        #expect(researcherBlob.contains("researcher-watch.md"))
        #expect(!researcherBlob.contains("researcher-vault.md"))
        #expect(store.effectiveWorkingFolder(for: store.bots.first { $0.id == researcher.id }!) == researcherVault.path)
    }

    @Test("watcher runs do not auto-load the Operator browser skill")
    func watcherRunSkipsSkillInjection() async throws {
        let (store, _) = tempStore()
        #expect(store.signUp(name: "A", email: "wfskill@b.com", password: "password1") == nil)
        let bot = store.createBot(from: BotTemplates.desktopOperator)
        let vault = try projectFolder()
        let watchFolder = try projectFolder()
        defer {
            try? FileManager.default.removeItem(at: vault)
            try? FileManager.default.removeItem(at: watchFolder)
        }
        try "vault\n".write(to: vault.appendingPathComponent("skills.md"), atomically: true, encoding: .utf8)
        try "watch\n".write(to: watchFolder.appendingPathComponent("inbox.md"), atomically: true, encoding: .utf8)
        store.updateBot(botId: bot.id, workingFolder: vault.path)
        try saveWatcher(
            store: store,
            name: "Folder-Organize",
            path: watchFolder.path,
            botId: bot.id,
            instructions: "paste these into Skills as SKILL.md"
        )
        let client = listFilesClient()
        store.chatCompleter = client
        let triggered = store.runFolderWatcherNow(id: store.folderWatchers.first { $0.botId == bot.id }!.id)
        // Assert the watcher actually fired. Discarding this turned a skip
        // ("bot is already running") into a missing-file failure with no clue
        // attached.
        #expect(triggered.hasPrefix("Triggered"), "watcher did not fire: \(triggered)")
        #expect(await store.waitForRunCompletion(botId: bot.id))
        let system = client.requests.first?.messages.first { $0.role == "system" }?.content ?? ""
        #expect(!system.contains("Matched skills for this turn"))
        #expect(system.contains("this run"))
        #expect(system.contains(watchFolder.path))
        let blob = messageBlob(store.threads[bot.id])
        #expect(blob.contains("inbox.md"))
        #expect(!blob.contains("skills.md"))
    }

    @Test("watcher shell mv can write inside the watch path")
    func watcherShellMovesInWatchPath() async throws {
        let (store, _) = tempStore()
        #expect(store.signUp(name: "A", email: "wfshell@b.com", password: "password1") == nil)
        let bot = store.createBot(name: "Scout", title: "ops")
        if let idx = store.bots.firstIndex(where: { $0.id == bot.id }) {
            store.bots[idx].autoApprove = true
        }
        let watchFolder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/GrizzyBotWatch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: watchFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: watchFolder) }
        let src = watchFolder.appendingPathComponent("photo.jpg")
        try "img\n".write(to: src, atomically: true, encoding: .utf8)
        try saveWatcher(store: store, name: "Folder-Organize", path: watchFolder.path, botId: bot.id)
        let dest = watchFolder.appendingPathComponent("Images/photo.jpg")
        let destDir = watchFolder.appendingPathComponent("Images")
        let command = "mkdir -p '\(destDir.path)' && mv '\(src.path)' '\(dest.path)'"
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        store.chatCompleter = QueueChatClient([
            ChatCompletionResponse(toolCalls: [LLMToolCall(
                id: "1",
                name: "shell",
                arguments: "{\"command\":\"\(escaped)\"}"
            )]),
            ChatCompletionResponse(text: "organized"),
        ])
        _ = store.runFolderWatcherNow(id: store.folderWatchers.first { $0.botId == bot.id }!.id)
        #expect(await store.waitForRunCompletion(botId: bot.id))
        #expect(FileManager.default.fileExists(atPath: dest.path))
        #expect(!FileManager.default.fileExists(atPath: src.path))
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
        #expect(prompt.contains("every bot"))
    }

    private func listFilesClient() -> QueueChatClient {
        QueueChatClient([
            ChatCompletionResponse(toolCalls: [LLMToolCall(
                id: "1",
                name: "list_files",
                arguments: "{}"
            )]),
            ChatCompletionResponse(text: "listed"),
        ])
    }

    private func saveWatcher(
        store: AppStore,
        name: String,
        path: String,
        botId: String,
        instructions: String = ""
    ) throws {
        var watcher = FolderWatcherRecord.makeNew()
        watcher.name = name
        watcher.watchPath = path
        watcher.instructions = instructions
        watcher.botId = botId
        try store.saveFolderWatcher(watcher)
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
