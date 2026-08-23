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
