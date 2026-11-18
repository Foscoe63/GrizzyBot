import Foundation
@testable import GrizzyBotCore
import NaturalLanguage
import Testing

private func makeVault(_ files: [String: String]) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("KnowledgeTests-\(UUID().uuidString)")
    for (rel, text) in files {
        let url = dir.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Suite("Knowledge index")
struct KnowledgeIndexTests {
    @Test("old saved sources decode as enabled")
    func decodesLegacySource() throws {
        let json = #"{"id":"a","name":"Docs","kind":"folder","path":"/tmp/x"}"#
        let source = try JSONDecoder().decode(KnowledgeSource.self, from: Data(json.utf8))
        #expect(source.enabled)
        #expect(source.roots.isEmpty)
        #expect(source.grantedBotIds.isEmpty)
    }

    @Test("frontmatter is stripped and sections carry their heading trail")
    func markdownSections() async throws {
        let dir = try makeVault([
            "policy.md": """
            ---
            title: Refund Policy
            tags: [secret-tag]
            ---
            # Overview
            General intro text.

            ## Digital goods
            Digital purchases can be returned within fourteen days.

            ## Hardware
            Hardware returns need the original packaging.
            """,
        ])
        let indexer = KnowledgeIndexer(semantic: false)
        let source = KnowledgeSource(name: "Docs", path: dir.path)
        let hits = await indexer.search(query: "original packaging", botId: nil, sources: [source])
        let top = try #require(hits.first)
        #expect(top.title == "Refund Policy › Overview › Hardware")
        #expect(top.snippet.contains("original packaging"))
        #expect(!top.snippet.contains("Digital purchases"))
        #expect(await indexer.search(query: "secret-tag", botId: nil, sources: [source]).isEmpty)
    }

    @Test("the tail of a long note is searchable")
    func longNoteTail() async throws {
        let filler = String(repeating: "Lorem ipsum dolor sit amet consectetur. ", count: 1_200)
        let dir = try makeVault(["long.md": "# Start\n" + filler + "\n\n# End\nThe launch codename is Bluebird."])
        let indexer = KnowledgeIndexer(semantic: false)
        let source = KnowledgeSource(name: "Docs", path: dir.path)
        let hits = await indexer.search(query: "bluebird codename", botId: nil, sources: [source])
        #expect(hits.first?.snippet.contains("Bluebird") == true)
    }

    @Test("skipped files are counted and explained")
    func fileLimitIsVisible() async throws {
        var files: [String: String] = [:]
        for i in 0..<7 { files["n\(i).md"] = "note number \(i)" }
        files["big.txt"] = String(repeating: "x", count: 2_100_000)
        let dir = try makeVault(files)
        let indexer = KnowledgeIndexer(maxFiles: 5, semantic: false)
        let source = KnowledgeSource(name: "Docs", path: dir.path)
        let stats = await indexer.refresh(source)
        #expect(stats.indexedFiles == 5)
        #expect(stats.skippedFiles == 3)
        #expect(stats.notes.contains { $0.contains("5-file limit") })
        #expect(stats.notes.contains { $0.contains("2 MB") })
        #expect(stats.summary.contains("5 files indexed, 3 skipped"))
    }

    @Test("unchanged files come from the cache and edits are picked up")
    func caching() async throws {
        let dir = try makeVault(["a.md": "alpha original", "b.md": "beta stays"])
        let indexer = KnowledgeIndexer(semantic: false)
        let source = KnowledgeSource(name: "Docs", path: dir.path)
        let first = await indexer.refresh(source)
        #expect(first.reparsedFiles == 2)
        let second = await indexer.refresh(source)
        #expect(second.reparsedFiles == 0)
        #expect(second.indexedFiles == 2)

        let url = dir.appendingPathComponent("a.md")
        try "alpha rewritten with zebra".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
        let hits = await indexer.search(query: "zebra", botId: nil, sources: [source])
        #expect(hits.first?.relativePath == "a.md")
        let third = await indexer.refresh(source)
        #expect(third.reparsedFiles == 0)

        try FileManager.default.removeItem(at: dir.appendingPathComponent("b.md"))
        #expect(await indexer.refresh(source).indexedFiles == 1)
    }

    @Test("subfolders limit what is indexed")
    func subfolders() async throws {
        let dir = try makeVault([
            "hr/leave.md": "vacation accrual rules",
            "eng/deploy.md": "vacation freeze before deploys",
        ])
        let indexer = KnowledgeIndexer(semantic: false)
        let source = KnowledgeSource(name: "Docs", path: dir.path, roots: ["hr"])
        let hits = await indexer.search(query: "vacation", botId: nil, sources: [source])
        #expect(hits.map(\.relativePath) == ["hr/leave.md"])
    }

    @Test("subfolders cannot climb out of the folder")
    func rejectsEscapingRoots() async throws {
        let outer = try makeVault([
            "vault/inside.md": "inside note",
            "secret/outside.md": "classified outside note",
        ])
        let vault = outer.appendingPathComponent("vault")
        let indexer = KnowledgeIndexer(semantic: false)
        for root in ["../secret", "../..", "/etc", "~"] {
            let source = KnowledgeSource(name: "Docs", path: vault.path, roots: [root])
            let stats = await indexer.refresh(source, force: true)
            #expect(stats.indexedFiles == 0, "root \(root) should be refused")
            #expect(stats.notes.contains { $0.contains("inside the source folder") })
            #expect(await indexer.search(query: "classified", botId: nil, sources: [source]).isEmpty)
        }
    }

    @Test("symlinks pointing outside the folder are not followed")
    func rejectsSymlinkEscape() async throws {
        let outer = try makeVault([
            "vault/inside.md": "inside note",
            "secret/passwords.md": "classified outside note",
        ])
        let vault = outer.appendingPathComponent("vault")
        let fm = FileManager.default
        try fm.createSymbolicLink(at: vault.appendingPathComponent("leak.md"), withDestinationURL: outer.appendingPathComponent("secret/passwords.md"))
        try fm.createSymbolicLink(at: vault.appendingPathComponent("linked"), withDestinationURL: outer.appendingPathComponent("secret"))

        let indexer = KnowledgeIndexer(semantic: false)
        let source = KnowledgeSource(name: "Docs", path: vault.path)
        let stats = await indexer.refresh(source)
        #expect(stats.indexedFiles == 1)
        #expect(stats.skippedFiles >= 1)
        #expect(await indexer.search(query: "classified", botId: nil, sources: [source]).isEmpty)

        let viaRoot = KnowledgeSource(name: "Docs", path: vault.path, roots: ["linked"])
        #expect(await indexer.refresh(viaRoot, force: true).indexedFiles == 0)
    }

    @Test("bot grants and the enabled switch decide who can search a source")
    func accessControl() async throws {
        let legal = try makeVault(["contract.md": "indemnity clause for suppliers"])
        let product = try makeVault(["spec.md": "indemnity of the product roadmap"])
        let indexer = KnowledgeIndexer(semantic: false)
        var sources = [
            KnowledgeSource(id: "legal", name: "Legal", path: legal.path, grantedBotIds: ["ada"]),
            KnowledgeSource(id: "product", name: "Product", path: product.path),
        ]

        func names(_ bot: String?) async -> Set<String> {
            Set(await indexer.search(query: "indemnity", botId: bot, sources: sources).map(\.sourceName))
        }
        #expect(await names("ada") == ["Legal", "Product"])
        #expect(await names("grace") == ["Product"])
        #expect(await names(nil) == ["Legal", "Product"])

        sources[1].enabled = false
        #expect(await names("ada") == ["Legal"])
        #expect(await names("grace").isEmpty)
        #expect(KnowledgePlane.sourcesVisible(to: "grace", from: sources).isEmpty)
        #expect(KnowledgePlane.sourcesVisible(to: "ada", from: sources).map(\.id) == ["legal"])
    }

    @Test("wikilinks are resolved and linked notes are surfaced")
    func wikilinks() async throws {
        let dir = try makeVault([
            "Onboarding.md": "# Onboarding\nNew hires read [[Security Basics|the basics]] and [[handbook/Benefits#Health]].",
            "Security Basics.md": "Use a password manager.",
            "handbook/Benefits.md": "Health cover starts day one.",
        ])
        #expect(KnowledgeMarkdown.wikilinks(in: "see [[A|b]] and [[Folder/C#h]] and [[a]]") == ["a", "c"])

        let indexer = KnowledgeIndexer(semantic: false)
        let source = KnowledgeSource(name: "Vault", path: dir.path)
        let hits = await indexer.search(query: "new hires read", botId: nil, sources: [source])
        let top = try #require(hits.first)
        #expect(top.relativePath == "Onboarding.md")
        #expect(Set(top.linked) == ["Security Basics.md", "handbook/Benefits.md"])
    }

    @Test("semantic search finds a note worded differently from the query")
    func semanticMatch() async throws {
        guard NLEmbedding.sentenceEmbedding(for: .english) != nil else { return }
        let dir = try makeVault([
            "returns.md": "# Returns\nCustomers may send back purchases within thirty days for their money back.",
            "lunch.md": "# Lunch\nThe cafeteria serves soup and sandwiches at noon.",
        ])
        let indexer = KnowledgeIndexer(semantic: true)
        let source = KnowledgeSource(name: "Docs", path: dir.path)
        let hits = await indexer.search(query: "refund policy", botId: nil, sources: [source])
        #expect(hits.first?.relativePath == "returns.md")
        #expect(hits.first?.semanticScore != nil)
    }
}
