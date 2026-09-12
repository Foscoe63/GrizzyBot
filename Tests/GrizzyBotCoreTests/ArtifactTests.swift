import Foundation
import Testing
@testable import GrizzyBotCore

private func makeStore() -> (ArtifactStore, URL) {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("artifact-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return (ArtifactStore(root: root), root)
}

@Suite("Artifact store")
struct ArtifactStoreTests {
    @Test("Create saves version 1 and mirrors a filename from the title")
    func createSavesFirstVersion() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let record = try store.create(
            id: "",
            title: "Morning Brief",
            kind: .markdown,
            language: nil,
            content: "# Brief\nhello",
            botId: "bot-1"
        )
        #expect(record.id == "morning-brief")
        #expect(record.versions.count == 1)
        #expect(record.versions[0].note == "Created")
        #expect(record.fileName == "morning-brief.md")  // id derived from the title
        #expect(record.botId == "bot-1")
        #expect(store.list().count == 1)
    }

    @Test("A second artifact cannot reuse an id")
    func duplicateIdRefused() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try store.create(id: "brief", title: "Brief", kind: .markdown, language: nil, content: "a", botId: nil)
        #expect(throws: ArtifactError.duplicateId("brief")) {
            _ = try store.create(id: "brief", title: "Other", kind: .markdown, language: nil, content: "b", botId: nil)
        }
    }

    @Test("Update replaces a unique passage and appends a version")
    func updateAppendsVersion() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try store.create(id: "doc", title: "Doc", kind: .markdown, language: nil, content: "alpha beta gamma", botId: nil)

        let updated = try store.update(id: "doc", oldString: "beta", newString: "BETA")
        #expect(updated.content == "alpha BETA gamma")
        #expect(updated.versions.count == 2)
        #expect(updated.versions.last?.content == "alpha BETA gamma")
        // History keeps the original.
        #expect(updated.versions.first?.content == "alpha beta gamma")
    }

    @Test("An ambiguous old_str is refused rather than guessed at")
    func ambiguousUpdateRefused() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try store.create(id: "doc", title: "Doc", kind: .code, language: "swift", content: "let x = 1\nlet x = 1", botId: nil)

        #expect(throws: ArtifactError.targetNotUnique("let x = 1", 2)) {
            _ = try store.update(id: "doc", oldString: "let x = 1", newString: "let y = 2")
        }
        // Nothing was written.
        #expect(store.load(id: "doc")?.versions.count == 1)
    }

    @Test("An old_str that is absent is reported, not silently ignored")
    func missingTargetRefused() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try store.create(id: "doc", title: "Doc", kind: .markdown, language: nil, content: "alpha", botId: nil)
        #expect(throws: ArtifactError.targetNotFound("omega")) {
            _ = try store.update(id: "doc", oldString: "omega", newString: "x")
        }
    }

    @Test("Rewrite replaces everything and can retitle")
    func rewriteReplaces() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try store.create(id: "doc", title: "Old", kind: .markdown, language: nil, content: "before", botId: nil)

        let rewritten = try store.rewrite(id: "doc", content: "after", title: "New")
        #expect(rewritten.content == "after")
        #expect(rewritten.title == "New")
        #expect(rewritten.versions.count == 2)
    }

    @Test("An artifact resolves by title when the id is lost")
    func loadsByTitle() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try store.create(id: "x1", title: "Quarterly Plan", kind: .markdown, language: nil, content: "a", botId: nil)
        #expect(store.load(id: "Quarterly Plan")?.id == "x1")
        #expect(store.load(id: "quarterly plan")?.id == "x1")
    }

    @Test("Delete removes the record and its folder")
    func deleteRemoves() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try store.create(id: "doc", title: "Doc", kind: .markdown, language: nil, content: "a", botId: nil)

        let removed = try store.delete(id: "doc")
        #expect(removed.title == "Doc")
        #expect(store.list().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("artifacts/doc").path))
        #expect(throws: ArtifactError.notFound("doc")) { _ = try store.delete(id: "doc") }
    }

    @Test("Artifacts survive a new store over the same root")
    func persistsAcrossInstances() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try store.create(id: "doc", title: "Doc", kind: .react, language: nil, content: "export default function App() {}", botId: "bot-9")

        let reopened = ArtifactStore(root: root)
        let found = reopened.load(id: "doc")
        #expect(found?.kind == .react)
        #expect(found?.botId == "bot-9")
    }

    @Test("Slugs stay filesystem-safe and never empty")
    func slugIsSafe() {
        #expect(ArtifactStore.slug("Morning Brief — 2026") == "morning-brief-2026")
        #expect(ArtifactStore.slug("../../etc/passwd") == "etc-passwd")
        #expect(ArtifactStore.slug("Hello!!!") == "hello")
        #expect(!ArtifactStore.slug("///").isEmpty)
        #expect(!ArtifactStore.slug("///").contains("/"))
    }
}

@Suite("Artifact kinds")
struct ArtifactKindTests {
    @Test("Claude Desktop's media types are accepted as-is")
    func parsesClaudeMediaTypes() {
        #expect(ArtifactKind.parse("application/vnd.ant.react") == .react)
        #expect(ArtifactKind.parse("application/vnd.ant.code") == .code)
        #expect(ArtifactKind.parse("text/markdown") == .markdown)
        #expect(ArtifactKind.parse("image/svg+xml") == .svg)
        #expect(ArtifactKind.parse("application/vnd.ant.mermaid") == .mermaid)
        #expect(ArtifactKind.parse("text/html") == .html)
    }

    @Test("Plain names and casing work too")
    func parsesPlainNames() {
        #expect(ArtifactKind.parse("React") == .react)
        #expect(ArtifactKind.parse(" markdown ") == .markdown)
        #expect(ArtifactKind.parse("jsx") == .react)
        #expect(ArtifactKind.parse("nonsense") == nil)
    }

    @Test("Only markdown and code render without a web frame")
    func webFrameKinds() {
        #expect(!ArtifactKind.markdown.needsWebFrame)
        #expect(!ArtifactKind.code.needsWebFrame)
        for kind in [ArtifactKind.html, .svg, .mermaid, .react] {
            #expect(kind.needsWebFrame)
        }
    }

    @Test("File extensions follow the language for code")
    func fileExtensions() {
        #expect(ArtifactKind.code.fileExtension(language: "python") == "py")
        #expect(ArtifactKind.code.fileExtension(language: "Swift") == "swift")
        #expect(ArtifactKind.code.fileExtension(language: nil) == "txt")
        #expect(ArtifactKind.code.fileExtension(language: "brainfuck") == "txt")
        #expect(ArtifactKind.react.fileExtension(language: nil) == "jsx")
        #expect(ArtifactKind.mermaid.fileExtension(language: nil) == "mmd")
    }
}

@Suite("Artifact frame")
struct ArtifactRuntimeTests {
    private func record(_ kind: ArtifactKind, _ content: String) -> ArtifactRecord {
        ArtifactRecord(id: "a", title: "A", kind: kind, content: content)
    }

    @Test("Every generated document closes the network and declares a policy")
    func policyIsPresent() {
        for kind in ArtifactKind.allCases {
            let doc = ArtifactRuntime.document(for: record(kind, "x"), dark: true)
            #expect(doc.contains("Content-Security-Policy"), "\(kind) has no policy")
            #expect(doc.contains("connect-src 'none'"), "\(kind) does not close the network")
            #expect(doc.contains("default-src 'none'"), "\(kind) has no default deny")
        }
    }

    @Test("Content is carried as base64, so quotes cannot break the boot script")
    func contentIsEscaped() {
        let hostile = "</script><script>alert(\"x\")</script>\"'`\\"
        let doc = ArtifactRuntime.document(for: record(.svg, hostile), dark: false)
        #expect(!doc.contains("alert("))
        #expect(doc.contains(ArtifactRuntime.base64(hostile)))
    }

    @Test("A full HTML artifact keeps its own document and gains the policy")
    func htmlKeepsDocument() {
        let raw = "<!doctype html><html><head><title>Hi</title></head><body><p>hello</p></body></html>"
        let doc = ArtifactRuntime.htmlDocument(raw, dark: false)
        #expect(doc.contains("<title>Hi</title>"))
        #expect(doc.contains("<p>hello</p>"))
        #expect(doc.contains("Content-Security-Policy"))
        #expect(doc.contains("tailwind.js"))
    }

    @Test("An HTML fragment is wrapped into a document")
    func htmlFragmentIsWrapped() {
        let doc = ArtifactRuntime.htmlDocument("<p>just a fragment</p>", dark: false)
        #expect(doc.contains("<!doctype html>"))
        #expect(doc.contains("<p>just a fragment</p>"))
        #expect(doc.contains("Content-Security-Policy"))
    }

    @Test("An html tag with no head still gets one")
    func htmlWithoutHeadGainsOne() {
        let doc = ArtifactRuntime.htmlDocument("<html lang=\"en\"><body>hi</body></html>", dark: false)
        #expect(doc.contains("<head>"))
        #expect(doc.contains("Content-Security-Policy"))
        #expect(doc.contains("<body>hi</body>"))
    }

    @Test("React documents load exactly the runtimes they need")
    func reactLoadsRuntimes() {
        let doc = ArtifactRuntime.document(for: record(.react, "export default function App() {}"), dark: true)
        for runtime in [ArtifactRuntime.Runtime.react, .reactDOM, .babel, .tailwind] {
            #expect(doc.contains(runtime.rawValue), "missing \(runtime.rawValue)")
        }
        #expect(!doc.contains(ArtifactRuntime.Runtime.mermaid.rawValue))
    }

    @Test("Mermaid documents load only mermaid")
    func mermaidLoadsRuntime() {
        let doc = ArtifactRuntime.document(for: record(.mermaid, "graph TD; A-->B;"), dark: true)
        #expect(doc.contains(ArtifactRuntime.Runtime.mermaid.rawValue))
        #expect(!doc.contains(ArtifactRuntime.Runtime.babel.rawValue))
    }

    @Test("SVG needs no runtime at all")
    func svgLoadsNothing() {
        let doc = ArtifactRuntime.document(for: record(.svg, "<svg/>"), dark: false)
        for runtime in ArtifactRuntime.Runtime.allCases {
            #expect(!doc.contains("src=\"\(runtime.rawValue)\""), "svg should not load \(runtime.rawValue)")
        }
    }

    @Test("The frame URL uses the private scheme")
    func frameURL() {
        #expect(ArtifactRuntime.indexURL?.scheme == ArtifactRuntime.scheme)
        #expect(ArtifactRuntime.indexURL?.absoluteString == "grizzy-artifact://frame/index.html")
    }
}

@Suite("Artifact tools")
@MainActor
struct ArtifactToolTests {
    private func tempStore() -> AppStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrizzyBotArtifactTools-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return AppStore(dataDirectory: dir, delayScale: 0.01)
    }

    private func bot(_ store: AppStore, email: String) -> Bot {
        #expect(store.signUp(name: "A", email: email, password: "password1") == nil)
        let bot = store.createBot(name: "Maker", title: "artifacts")
        if let idx = store.bots.firstIndex(where: { $0.id == bot.id }) {
            store.bots[idx].autoApprove = true
        }
        return bot
    }

    @Test("A bot drives create, update, and delete through the tool loop")
    func toolRoundTrip() async {
        let store = tempStore()
        let bot = bot(store, email: "artifact1@b.com")

        store.chatCompleter = QueueChatClient([
            ChatCompletionResponse(toolCalls: [LLMToolCall(
                id: "1",
                name: "artifact_create",
                arguments: ##"{"id":"brief","title":"Daily Brief","type":"markdown","content":"# Brief\nfirst line"}"##
            )]),
            ChatCompletionResponse(text: "made it"),
        ])
        store.send(botId: bot.id, text: "make a brief")
        #expect(await store.waitForRunCompletion(botId: bot.id))

        let created = store.artifact(id: "brief")
        #expect(created?.title == "Daily Brief")
        #expect(created?.kind == .markdown)
        #expect(created?.versions.count == 1)
        // The artifact is also mirrored to disk as a real file.
        #expect(created?.mirroredPath == "brief.md")
        #expect(store.readBotHomeFile(botId: bot.id, path: "brief.md")?.contains("first line") == true)

        store.chatCompleter = QueueChatClient([
            ChatCompletionResponse(toolCalls: [LLMToolCall(
                id: "2",
                name: "artifact_update",
                arguments: #"{"id":"brief","old_str":"first line","new_str":"second line"}"#
            )]),
            ChatCompletionResponse(text: "updated"),
        ])
        store.send(botId: bot.id, text: "change it")
        #expect(await store.waitForRunCompletion(botId: bot.id))

        let updated = store.artifact(id: "brief")
        #expect(updated?.content.contains("second line") == true)
        #expect(updated?.versions.count == 2)
        #expect(store.readBotHomeFile(botId: bot.id, path: "brief.md")?.contains("second line") == true)

        store.chatCompleter = QueueChatClient([
            ChatCompletionResponse(toolCalls: [LLMToolCall(
                id: "3",
                name: "artifact_delete",
                arguments: #"{"id":"brief"}"#
            )]),
            ChatCompletionResponse(text: "gone"),
        ])
        store.send(botId: bot.id, text: "delete it")
        #expect(await store.waitForRunCompletion(botId: bot.id))
        #expect(store.artifact(id: "brief") == nil)
    }

    @Test("A routine tick creates an artifact without opening a panel")
    func routineCreatesArtifact() async {
        let store = tempStore()
        let bot = bot(store, email: "artifact2@b.com")

        store.chatCompleter = QueueChatClient([
            ChatCompletionResponse(toolCalls: [LLMToolCall(
                id: "1",
                name: "artifact_create",
                arguments: ##"{"id":"morning","title":"Morning Brief","type":"markdown","content":"# Morning"}"##
            )]),
            ChatCompletionResponse(text: "done"),
        ])
        store.headlessRoutineTick = true
        store.send(botId: bot.id, text: "run the brief")
        #expect(await store.waitForRunCompletion(botId: bot.id))

        #expect(store.artifact(id: "morning")?.title == "Morning Brief")
        // Headless means headless: the artifact exists, nothing was yanked open.
        #expect(store.panel == nil)
    }

    @Test("A bad type is reported instead of creating the wrong artifact")
    func unknownTypeReported() async {
        let store = tempStore()
        let bot = bot(store, email: "artifact3@b.com")

        store.chatCompleter = QueueChatClient([
            ChatCompletionResponse(toolCalls: [LLMToolCall(
                id: "1",
                name: "artifact_create",
                arguments: #"{"id":"x","title":"X","type":"powerpoint","content":"hi"}"#
            )]),
            ChatCompletionResponse(text: "could not"),
        ])
        store.send(botId: bot.id, text: "make it")
        #expect(await store.waitForRunCompletion(botId: bot.id))
        #expect(store.artifact(id: "x") == nil)
        #expect(store.artifacts.isEmpty)
    }

    @Test("The panel can create an artifact by hand, and it mirrors to disk")
    func createByHand() {
        let store = tempStore()
        let bot = bot(store, email: "artifact5@b.com")
        store.selectBot(bot.id)

        let record = store.createArtifact(title: "Release Notes", kind: .markdown)
        #expect(record?.id == "release-notes")
        #expect(record?.title == "Release Notes")
        #expect(store.activeArtifactId == "release-notes")
        // Starter content, not an empty artifact the store would have refused.
        #expect(record?.content.isEmpty == false)
        #expect(record?.mirroredPath == "release-notes.md")
        #expect(store.readBotHomeFile(botId: bot.id, path: "release-notes.md")?.isEmpty == false)
    }

    @Test("An untitled hand-made artifact still gets a usable name")
    func createByHandUntitled() {
        let store = tempStore()
        _ = bot(store, email: "artifact6@b.com")
        let record = store.createArtifact(title: "   ", kind: .react)
        #expect(record?.title == "Untitled")
        #expect(record?.id == "untitled")
        #expect(record?.fileName == "untitled.jsx")
    }

    @Test("Every kind's starter content is real content a frame can render")
    func starterContentIsRenderable() {
        let store = tempStore()
        _ = bot(store, email: "artifact7@b.com")
        for kind in ArtifactKind.allCases {
            let record = store.createArtifact(title: "Start \(kind.rawValue)", kind: kind)
            #expect(record != nil, "\(kind) could not be created")
            #expect(record?.content.isEmpty == false, "\(kind) has empty starter content")
        }
        #expect(store.artifacts.count == ArtifactKind.allCases.count)
    }

    @Test("The artifact panel toggles open and closed")
    func panelToggles() {
        let store = tempStore()
        _ = bot(store, email: "artifact8@b.com")
        #expect(store.panel == nil)
        store.toggleArtifactPanel()
        #expect(store.panel == .artifact)
        store.toggleArtifactPanel()
        #expect(store.panel == nil)
    }

    @Test("Opening the panel selects an existing artifact so it is reachable after a restart")
    func panelFindsExistingArtifacts() {
        let store = tempStore()
        _ = bot(store, email: "artifact9@b.com")
        _ = store.createArtifact(title: "Kept", kind: .markdown)
        // Forget the selection, the way a fresh launch would.
        store.activeArtifactId = nil
        store.panel = nil

        store.toggleArtifactPanel()
        #expect(store.panel == .artifact)
        #expect(store.activeArtifactId == "kept")
    }

    @Test("A hand edit saves as a new version and re-mirrors the file")
    func editSavesNewVersion() {
        let store = tempStore()
        let bot = bot(store, email: "artifactA@b.com")
        store.selectBot(bot.id)
        let created = store.createArtifact(title: "Notes", kind: .markdown, content: "first")
        #expect(created?.versions.count == 1)

        let outcome = store.saveArtifactEdit(id: "notes", content: "second", baseVersionCount: 1)
        #expect(outcome == .saved)

        let saved = store.artifact(id: "notes")
        #expect(saved?.content == "second")
        #expect(saved?.versions.count == 2)
        // History is append-only: the original is still readable.
        #expect(saved?.versions.first?.content == "first")
        #expect(store.readBotHomeFile(botId: bot.id, path: "notes.md") == "second")
    }

    @Test("Saving identical content writes no version")
    func editUnchangedWritesNothing() {
        let store = tempStore()
        _ = bot(store, email: "artifactB@b.com")
        _ = store.createArtifact(title: "Notes", kind: .markdown, content: "same")

        #expect(store.saveArtifactEdit(id: "notes", content: "same", baseVersionCount: 1) == .unchanged)
        #expect(store.artifact(id: "notes")?.versions.count == 1)
    }

    @Test("A save that lands on top of a bot's edit says so, and loses nothing")
    func editReportsConcurrentWrite() async {
        let store = tempStore()
        let bot = bot(store, email: "artifactC@b.com")
        store.selectBot(bot.id)
        _ = store.createArtifact(title: "Notes", kind: .markdown, content: "original")

        // The editor opens against version 1.
        let base = store.artifact(id: "notes")?.versions.count ?? 0
        #expect(base == 1)

        // A bot writes while the editor is open.
        store.chatCompleter = QueueChatClient([
            ChatCompletionResponse(toolCalls: [LLMToolCall(
                id: "1",
                name: "artifact_rewrite",
                arguments: #"{"id":"notes","content":"from the bot"}"#
            )]),
            ChatCompletionResponse(text: "done"),
        ])
        store.send(botId: bot.id, text: "update it")
        #expect(await store.waitForRunCompletion(botId: bot.id))
        #expect(store.artifact(id: "notes")?.versions.count == 2)

        let outcome = store.saveArtifactEdit(id: "notes", content: "from the person", baseVersionCount: base)
        #expect(outcome == .savedOverNewerVersions(1))

        let saved = store.artifact(id: "notes")
        #expect(saved?.content == "from the person")
        #expect(saved?.versions.count == 3)
        // The bot's version survives in history.
        #expect(saved?.versions.contains { $0.content == "from the bot" } == true)
    }

    @Test("Editing an older version restores it as the newest one")
    func editingOldVersionRestoresIt() {
        let store = tempStore()
        _ = bot(store, email: "artifactD@b.com")
        _ = store.createArtifact(title: "Notes", kind: .markdown, content: "v1")
        _ = store.saveArtifactEdit(id: "notes", content: "v2", baseVersionCount: 1)

        // Re-save the first version's content, the way the panel does when you
        // step back and hit Edit → Save.
        let first = store.artifact(id: "notes")?.versions.first?.content ?? ""
        #expect(first == "v1")
        #expect(store.saveArtifactEdit(id: "notes", content: first, baseVersionCount: 2) == .saved)

        let saved = store.artifact(id: "notes")
        #expect(saved?.content == "v1")
        #expect(saved?.versions.count == 3)
    }

    @Test("Saving to a deleted artifact fails instead of resurrecting it")
    func editMissingArtifactFails() {
        let store = tempStore()
        _ = bot(store, email: "artifactE@b.com")
        let outcome = store.saveArtifactEdit(id: "gone", content: "x", baseVersionCount: 1)
        guard case .failed = outcome else {
            Issue.record("expected a failure, got \(outcome)")
            return
        }
        #expect(store.artifact(id: "gone") == nil)
    }

    @Test("Artifact tools are on by default for a new bot")
    func enabledByDefault() {
        let store = tempStore()
        let bot = bot(store, email: "artifact4@b.com")
        for id in ArtifactStore.toolIds {
            #expect(bot.isToolEnabled(id), "\(id) is not enabled")
        }
    }
}
