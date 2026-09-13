import Foundation
import GrizzyBotCore
import Testing

@Suite("CapabilitySearch")
struct CapabilitySearchTests {
    @Test("discovers skills by keyword")
    func discoverSkills() {
        let skill = AgentSkill(
            id: "research",
            name: "research",
            description: "Deep web research and synthesis",
            body: "Do research",
            keywords: ["web", "search"]
        )
        let entries = CapabilitySearch.entries(skills: [skill], builtins: [], mcpAdvertised: [:])
        let hits = CapabilitySearch.search("research web", in: entries, topK: 5)
        #expect(hits.contains(where: { $0.entry.id == "research" }))
    }

    @Test("ranks mcp advertised tools")
    func discoverMcp() {
        let entries = CapabilitySearch.entries(
            skills: [],
            builtins: [],
            mcpAdvertised: ["tp": ["gmail__messages_list", "obsidian__search"]]
        )
        let hits = CapabilitySearch.search("gmail inbox", in: entries, topK: 5)
        #expect(hits.first?.entry.id == "gmail__messages_list")
    }
}

@Suite("PrivacyFilter")
struct PrivacyFilterTests {
    @Test("redacts email and api key")
    func redactBasics() {
        let text = "Email me at alice@example.com with key sk-abcdefghijklmnopqrstuvwxyz012345"
        let result = PrivacyFilter.redact(text)
        #expect(result.wasModified)
        #expect(result.redactedText.contains("[REDACTED EMAIL]"))
        #expect(result.redactedText.contains("[REDACTED API_KEY]"))
        #expect(result.hasCriticalPII)
    }

    @Test("fail closed blocks critical PII")
    func failClosed() {
        let settings = PrivacyFilterSettings(enabled: true, redactBeforeCloudSend: true, failClosed: true)
        #expect(throws: PrivacyFilterBlockedError.self) {
            _ = try PrivacyFilter.applyForSend(
                "token sk-abcdefghijklmnopqrstuvwxyz012345",
                settings: settings
            )
        }
    }

    @Test("disabled passes through")
    func disabled() {
        let settings = PrivacyFilterSettings(enabled: false)
        let out = try! PrivacyFilter.applyForSend("sk-abcdefghijklmnopqrstuvwxyz012345", settings: settings)
        #expect(out.contains("sk-"))
    }
}

@Suite("MemoryLean")
struct MemoryLeanTests {
    @Test("gate skips greetings")
    func gateNone() {
        #expect(MemoryRelevanceGate.decide(query: "hi", mode: .heuristic) == .none)
    }

    @Test("gate picks identity")
    func gateIdentity() {
        #expect(MemoryRelevanceGate.decide(query: "who am i?", mode: .heuristic) == .identity)
    }

    @Test("dedupe merges similar facts")
    func dedupe() {
        let content = """
        # Memory

        ## Pin

        ## Facts

        - Prefer dark mode always
        - Always prefer dark mode
        - Unrelated fact about coffee
        """
        let result = MemoryFactDedupe.mergeContent(content, threshold: 0.5)
        #expect(result.removed.count >= 1)
        #expect(result.text.contains("coffee"))
    }

    @Test("rrf fuses ranks")
    func rrf() {
        let fused = MemoryHybridSearch.reciprocalRankFusion(
            textIDs: ["a", "b", "c"],
            vectorIDs: ["c", "a"],
            limit: 2
        )
        #expect(fused.count == 2)
        #expect(fused.contains("a") || fused.contains("c"))
    }
}

@Suite("Memory embeddings")
struct MemoryEmbeddingTests {
    private func doc(_ path: String, _ content: String) -> MemoryDocument {
        MemoryDocument(id: path, scope: "bot", botId: "b1", path: path, content: content, revision: 1, updatedAt: .now)
    }

    @Test("cosine is 1 for identical, 0 for orthogonal and for degenerate input")
    func cosine() {
        let a = MemoryVector([1, 0, 0])
        let b = MemoryVector([1, 0, 0])
        let c = MemoryVector([0, 1, 0])
        #expect(abs(MemoryVector.cosine(a, b) - 1) < 0.000_001)
        #expect(abs(MemoryVector.cosine(a, c)) < 0.000_001)
        // Degenerate: zero magnitude, mismatched length, empty.
        #expect(MemoryVector.cosine(a, MemoryVector([0, 0, 0])) == 0)
        #expect(MemoryVector.cosine(a, MemoryVector([1, 0])) == 0)
        #expect(MemoryVector.cosine(MemoryVector([]), MemoryVector([])) == 0)
    }

    @Test("an unavailable embedder yields no vectors and no semantic hits")
    func unavailableEmbedder() {
        let embedder = MemoryEmbedder.unavailable
        #expect(!embedder.isAvailable)
        #expect(embedder.vector(for: "anything at all") == nil)

        let hits = MemorySemanticIndex.rank(
            documents: [doc("MEMORY.md", "the deploy pipeline signs the app")],
            query: "deploy",
            botId: "b1",
            embedder: embedder
        )
        #expect(hits.isEmpty)
    }

    @Test("keyword retrieval still works when embeddings are unavailable")
    func fallsBackToKeywords() {
        let documents = [doc("MEMORY.md", "The release pipeline notarizes the app before upload.")]
        let hits = MemoryHybridSearch.search(
            documents: documents,
            query: "notarizes",
            botId: "b1",
            embedder: .unavailable
        )
        #expect(!hits.isEmpty)
        #expect(hits.contains { $0.snippet.contains("notarizes") })
    }

    @Test("the cache embeds a given text once")
    func cacheDedupes() throws {
        let embedder = MemoryEmbedder()
        try #require(embedder.isAvailable)
        #expect(embedder.cachedCount == 0)
        _ = embedder.vector(for: "the routine failed to run this morning")
        let afterFirst = embedder.cachedCount
        _ = embedder.vector(for: "the routine failed to run this morning")
        #expect(embedder.cachedCount == afterFirst)
        _ = embedder.vector(for: "something else entirely")
        #expect(embedder.cachedCount == afterFirst + 1)
    }

    @Test("the cache evicts oldest first rather than growing without bound")
    func cacheEvicts() throws {
        let embedder = MemoryEmbedder(cacheLimit: 2)
        try #require(embedder.isAvailable)
        _ = embedder.vector(for: "first entry about routines")
        _ = embedder.vector(for: "second entry about artifacts")
        _ = embedder.vector(for: "third entry about skills")
        #expect(embedder.cachedCount == 2)
    }

    @Test("semantic retrieval surfaces a passage sharing no keyword with the query")
    func semanticRecall() throws {
        let embedder = MemoryEmbedder()
        try #require(embedder.isAvailable)

        // Zero token overlap — the tokenizer keeps every word of two characters
        // or more, stopwords included, so "the" in both would have been enough
        // for BM25 to find it and this test would prove nothing.
        // Measured: cosine 0.481 here, against 0.132 for unrelated prose.
        let documents = [doc("MEMORY.md", "The nightly routine silently failed to start at dawn.")]
        let query = "scheduled job never fired"

        let keyword = MemoryIndex.search(documents: documents, query: query, botId: "b1")
        let semantic = MemorySemanticIndex.rank(
            documents: documents,
            query: query,
            botId: "b1",
            embedder: embedder
        )

        #expect(keyword.isEmpty, "this passage is meant to be invisible to BM25")
        #expect(!semantic.isEmpty, "the semantic lane should reach it")

        // And the fused search returns it, which the old salience lane could not.
        let hybrid = MemoryHybridSearch.search(
            documents: documents,
            query: query,
            botId: "b1",
            embedder: embedder
        )
        #expect(!hybrid.isEmpty)
    }

    @Test("unrelated text is filtered by the similarity floor")
    func floorRejectsNoise() throws {
        let embedder = MemoryEmbedder()
        try #require(embedder.isAvailable)
        let hits = MemorySemanticIndex.rank(
            documents: [doc("MEMORY.md", "Banana bread recipe with walnuts and cinnamon.")],
            query: "scheduled job never fired",
            botId: "b1",
            embedder: embedder
        )
        #expect(hits.isEmpty)
    }
}

@Suite("FolderWatcherGlob")
struct FolderWatcherGlobTests {
    @Test("exclude and include globs")
    func globs() {
        #expect(
            FolderWatcherGlobMatching.matches(
                relativePath: "src/main.swift",
                includeGlobs: ["**/*.swift"],
                excludeGlobs: [".git/**"]
            )
        )
        #expect(
            !FolderWatcherGlobMatching.matches(
                relativePath: ".git/config",
                includeGlobs: [],
                excludeGlobs: [".git/**"]
            )
        )
    }
}

@Suite("FolderWatcherFirePolicy")
struct FolderWatcherFirePolicyTests {
    @Test("busy bots never fire; cooldown only blocks automatic events")
    func skipReasons() {
        #expect(
            FolderWatcherFirePolicy.skipReason(botBusy: true, suppressed: false, manual: true)
                == "Skipped: bot is already running."
        )
        #expect(
            FolderWatcherFirePolicy.skipReason(botBusy: false, suppressed: true, manual: false)
                == "Skipped: watcher is cooling down."
        )
        #expect(FolderWatcherFirePolicy.skipReason(botBusy: false, suppressed: true, manual: true) == nil)
        #expect(FolderWatcherFirePolicy.skipReason(botBusy: false, suppressed: false, manual: false) == nil)
    }

    @Test("suppress bumps generation so in-flight timers cannot fire")
    func generationBumps() {
        let id = UUID().uuidString
        #expect(!FolderWatcherSuppression.shared.isSuppressed(id))
        let first = FolderWatcherSuppression.shared.suppress(id)
        #expect(FolderWatcherSuppression.shared.isSuppressed(id))
        let second = FolderWatcherSuppression.shared.suppress(id)
        #expect(second != first)
        FolderWatcherSuppression.shared.release(id)
        #expect(!FolderWatcherSuppression.shared.isSuppressed(id))
        #expect(FolderWatcherSuppression.shared.currentGeneration(id) == second)
    }
}

@Suite("MacUseArgDefaults")
struct MacUseArgDefaultsTests {
    @Test("get_tool_definitions defaults names to *")
    func defaults() {
        let out = McpCallArguments.applyToolDefaults(
            toolName: "get_tool_definitions",
            args: [:]
        )
        #expect(out["names"] == .array([.string("*")]))
    }
}

@Suite("AgentSessionTools")
struct AgentSessionToolsTests {
    @Test("todo requires checkboxes")
    func todoParse() async {
        let bad = await AgentSessionTools.handleTodo(markdown: "- item without box", threadKey: "t1")
        #expect(bad.output.contains("No checklist"))
        let good = await AgentSessionTools.handleTodo(
            markdown: "- [ ] One\n- [x] Two",
            threadKey: "t1"
        )
        #expect(good.output.contains("1/2"))
    }

    @Test("complete ends turn")
    func completeEnds() async {
        let result = await AgentSessionTools.handleComplete(summary: "Done", threadKey: "t2")
        #expect(result.endTurn)
        #expect(result.output.contains("Done"))
    }
}
