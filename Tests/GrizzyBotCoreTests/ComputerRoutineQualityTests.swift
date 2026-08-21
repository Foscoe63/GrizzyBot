import CoreGraphics
import Foundation
import GrizzyBotCore
import ImageIO
import Testing

@Suite("Computer coordinates")
struct ComputerCoordinatesTests {
    @Test("screenshot pixels map into the same frame the image used")
    func mapsIntoFrame() {
        let frame = ComputerScreenFrame(
            originX: 100,
            originY: 50,
            pointWidth: 1000,
            pointHeight: 500,
            pixelWidth: 2000,
            pixelHeight: 1000
        )
        let mid = ComputerCoordinates.pointInFrame(x: 1000, y: 500, frame: frame)
        #expect(abs(mid.x - 600) < 0.01)
        #expect(abs(mid.y - 300) < 0.01)
        let origin = ComputerCoordinates.pointInFrame(x: 0, y: 0, frame: frame)
        #expect(origin.x == 100)
        #expect(origin.y == 50)
    }

    @Test("cocoa bottom-left converts to CGEvent top-left")
    func cocoaToCGEvent() {
        let point = ComputerCoordinates.cgEventPoint(cocoaX: 10, cocoaY: 200, primaryMaxY: 800)
        #expect(point.x == 10)
        #expect(point.y == 600)
    }

    @Test("Retina screenshot click lands on the cocoa frame")
    func retinaClick() {
        let frame = ComputerScreenFrame(
            pointWidth: 1440,
            pointHeight: 900,
            pixelWidth: 2880,
            pixelHeight: 1800
        )
        let cg = ComputerCoordinates.cgEventPoint(
            screenshotX: 2880,
            screenshotY: 0,
            frame: frame,
            cocoaFrameOriginX: 0,
            cocoaFrameOriginY: 0,
            cocoaFrameHeight: 900,
            primaryMaxY: 900
        )
        #expect(abs(cg.x - 1440) < 0.5)
        #expect(abs(cg.y - 0) < 0.5)
        let back = ComputerCoordinates.screenshotPoint(
            cgEventX: cg.x,
            cgEventY: cg.y,
            frame: frame,
            cocoaFrameOriginX: 0,
            cocoaFrameOriginY: 0,
            cocoaFrameHeight: 900,
            primaryMaxY: 900
        )
        #expect(abs(back.x - 2880) < 1)
        #expect(abs(back.y - 0) < 1)
    }

    @Test("display stacked above the primary uses the primary maxY")
    func stackedDisplay() {
        let frame = ComputerScreenFrame(
            pointWidth: 1440,
            pointHeight: 900,
            pixelWidth: 1440,
            pixelHeight: 900
        )
        let topLeft = ComputerCoordinates.cgEventPoint(
            screenshotX: 0,
            screenshotY: 0,
            frame: frame,
            cocoaFrameOriginX: 0,
            cocoaFrameOriginY: 900,
            cocoaFrameHeight: 900,
            primaryMaxY: 900
        )
        #expect(abs(topLeft.x - 0) < 0.5)
        #expect(abs(topLeft.y - (-900)) < 0.5)
    }

    @Test("key chords parse modifiers")
    func keyChords() {
        let copy = ComputerKeyMap.parse("cmd+c")
        #expect(copy.command)
        #expect(copy.virtualKey == 8)
        #expect(!copy.shift)
        let enter = ComputerKeyMap.parse("shift+enter")
        #expect(enter.shift)
        #expect(enter.virtualKey == 36)
        #expect(ComputerInput.Kind.scroll.usesScreenshotPoint)
        #expect(!ComputerInput.Kind.key.usesScreenshotPoint)
    }
}

@Suite("Computer outline")
struct ComputerOutlineTests {
    @Test("formats and caps target lines")
    func formats() {
        let line = ComputerOutline.line(tag: "button", title: "Save", x: 10, y: 20, width: 80, height: 24)
        #expect(line == "button \"Save\" @ (10,20,80x24)")
        let many = (0..<80).map { ComputerOutline.line(tag: "a", title: "n\($0)", x: $0, y: 0) }
        let text = ComputerOutline.format(lines: many)
        #expect(text.contains("…20 more"))
        #expect(text.split(whereSeparator: \.isNewline).count <= ComputerOutline.maxLines + 1)
    }
}

@Suite("File desktop")
struct FileDesktopRuntimeTests {
    @Test("records right-click scroll and double-click")
    func extraKinds() async {
        let runtime = FileDesktopRuntime()
        let right = await runtime.send(ComputerInput(kind: .rightClick, x: 10, y: 20), botId: "b")
        #expect(right.summary.contains("Right-clicked"))
        let dbl = await runtime.send(ComputerInput(kind: .doubleClick, x: 4, y: 8), botId: "b")
        #expect(dbl.summary.contains("Double-clicked"))
        let scroll = await runtime.send(ComputerInput(kind: .scroll, x: 1, y: 2, text: "-80"), botId: "b")
        #expect(scroll.summary.contains("Scrolled"))
    }
}

@Suite("Memory retrieval")
struct MemoryRetrievalTests {
    @Test("search_memory only returns this bot plus shared")
    func scopedToBot() {
        let docs = [
            MemoryDocument(id: "1", botId: "alice", path: "MEMORY.md", content: "- Alice secret token zebra"),
            MemoryDocument(id: "2", botId: "bob", path: "MEMORY.md", content: "- Bob secret token zebra"),
            MemoryDocument(
                id: "3",
                scope: "workspace",
                path: "SHARED.md",
                content: "- Shared zebra lives here"
            ),
        ]
        let hits = MemoryIndex.search(documents: docs, query: "zebra", botId: "alice")
        #expect(hits.contains(where: { $0.snippet.contains("Alice") }))
        #expect(hits.contains(where: { $0.snippet.contains("Shared") }))
        #expect(!hits.contains(where: { $0.snippet.contains("Bob") }))
    }

    @Test("BM25 prefers the denser matching chunk over a stray word")
    func bm25Ranks() {
        let docs = [
            MemoryDocument(
                id: "1",
                botId: "b",
                path: "MEMORY.md",
                content: """
                # Memory

                - Deploy window is Friday only
                - The Zendesk subdomain for production is acme.zendesk.com and agents must use it
                - Lunch is tacos
                """
            ),
        ]
        let hits = MemoryIndex.search(documents: docs, query: "zendesk subdomain production", botId: "b")
        #expect(hits.first?.snippet.contains("acme.zendesk.com") == true)
    }

    @Test("excerpt keeps pins and newest facts, not the oldest head")
    func recencyExcerpt() {
        let content = """
        # Memory

        ## Pin
        - standing-rule-pacific

        ## Facts
        - oldest-alpha-fact-that-is-quite-long
        - newest-omega-fact-that-is-quite-long
        """
        let text = MemoryIndex.excerpt(content, maxChars: 160)
        #expect(text.contains("standing-rule-pacific"))
        #expect(text.contains("omega"))
        #expect(text.contains("search_memory"))
        #expect(!text.contains("alpha"))
    }

    @Test("remember upserts a similar fact instead of appending")
    func upsertReplaces() {
        let start = MemoryLedger.botTemplate
        let first = MemoryLedger.upsert(content: start, fact: "Favorite color is blue")
        #expect(first.result == .inserted)
        let second = MemoryLedger.upsert(content: first.text, fact: "Favorite color is red")
        #expect(second.result == .updated(previous: "Favorite color is blue"))
        #expect(second.text.contains("red"))
        #expect(!second.text.contains("blue"))
        let secret = MemoryLedger.upsert(content: second.text, fact: "api_key=sk-live-secret")
        #expect(secret.result == .rejectedSecret)
        #expect(secret.text == second.text)
    }

    @Test("forget removes matching bullets")
    func forgetMatch() {
        let start = MemoryLedger.upsert(
            content: MemoryLedger.botTemplate,
            fact: "Deploy window is Friday only"
        ).text
        let withColor = MemoryLedger.upsert(content: start, fact: "Favorite color is blue").text
        let result = MemoryLedger.forget(content: withColor, query: "favorite color")
        #expect(result.removed.contains(where: { $0.lowercased().contains("color") }))
        #expect(result.text.contains("Friday"))
        #expect(!result.text.contains("blue"))
    }

    @Test("upsert keeps freeform lines that were not bullets")
    func preservesProse() {
        let content = """
        # Memory

        User likes short replies.
        """
        let written = MemoryLedger.upsert(content: content, fact: "Timezone is US/Pacific")
        #expect(written.text.contains("short replies"))
        #expect(written.text.contains("US/Pacific"))
    }

    @Test("pin upsert lands under ## Pin")
    func pinUpsert() {
        let first = MemoryLedger.upsert(content: MemoryLedger.botTemplate, fact: "Always reply in English", pin: true)
        #expect(first.result == .inserted)
        let pinSection = first.text.components(separatedBy: "## Facts").first ?? ""
        #expect(pinSection.contains("Always reply in English"))
        let moved = MemoryLedger.upsert(content: first.text, fact: "Always reply in English, briefly", pin: true)
        #expect(moved.result == .updated(previous: "Always reply in English"))
        #expect(moved.text.contains("briefly"))
        #expect(!moved.text.contains("- Always reply in English\n"))
    }

    @Test("paragraph chunks keep a multi-line fact together")
    func chunksParagraphs() {
        let docs = [
            MemoryDocument(
                id: "1",
                botId: "b",
                path: "MEMORY.md",
                content: """
                # Memory

                Preferred stack:
                Swift 6 on macOS
                with a local LM Studio model.

                Unrelated: buy milk
                """
            ),
        ]
        let hits = MemoryIndex.search(documents: docs, query: "LM Studio Swift", botId: "b")
        #expect(hits.contains(where: { $0.snippet.contains("LM Studio") }))
    }
}

@Suite("Computer mode migration")
struct ComputerModeMigrationTests {
    @Test("legacy cloud and docker decode as in-app browser")
    func decodeLegacy() throws {
        #expect(ComputerMode.parse("cloud") == .inAppBrowser)
        #expect(ComputerMode.parse("docker") == .inAppBrowser)
        #expect(ComputerMode.parse("vm") == .inAppBrowser)
        #expect(ComputerMode.parse("local") == .thisMac)
        #expect(ComputerMode.selectableCases == [.auto, .inAppBrowser, .thisMac, .off])
        #expect(ComputerMode.inAppBrowser.label == "In-app browser")

        let data = Data(#""cloud""#.utf8)
        let decoded = try JSONDecoder().decode(ComputerMode.self, from: data)
        #expect(decoded == .inAppBrowser)

        let encoded = try JSONEncoder().encode(ComputerMode.inAppBrowser)
        #expect(String(data: encoded, encoding: .utf8) == #""in-app-browser""#)
    }

    @Test("legacy docker sandbox becomes browser")
    func sandboxKind() throws {
        let docker = try JSONDecoder().decode(SandboxKind.self, from: Data(#""docker""#.utf8))
        #expect(docker == .browser)
        let fake = try JSONDecoder().decode(SandboxKind.self, from: Data(#""fake""#.utf8))
        #expect(fake == .none)
        #expect(ComputerHost.normalize("cloud") == .inAppBrowser)
    }
}

@Suite("Routine tick policy")
struct RoutineTickPolicyTests {
    @Test("caps concurrent routine runs at two")
    func cap() {
        #expect(RoutineTickPolicy.admit(dueCount: 5, activeRoutineRuns: 0) == 2)
        #expect(RoutineTickPolicy.admit(dueCount: 5, activeRoutineRuns: 2) == 0)
        #expect(RoutineTickPolicy.admit(dueCount: 1, activeRoutineRuns: 1) == 1)
    }

    @Test("skips scheduled runs when no model is connected")
    func skipNoModel() {
        #expect(RoutineTickPolicy.skipReason(canRunLLM: true) == nil)
        #expect(RoutineTickPolicy.skipReason(canRunLLM: false)?.contains("no model") == true)
    }
}

@Suite("Screenshot quality")
struct ScreenshotQualityTests {
    @Test("detects all-white jpeg as blank and painted desktop as not blank")
    func blankDetection() {
        let white = Self.solidJPEG(red: 1, green: 1, blue: 1)
        let painted = Self.solidJPEG(red: 0.1, green: 0.2, blue: 0.3)
        #expect(ScreenshotQuality.isBlankJPEG(white))
        #expect(!ScreenshotQuality.isBlankJPEG(painted))
        #expect(ScreenshotQuality.isBlankJPEG(Data()))
    }

    private static func solidJPEG(red: CGFloat, green: CGFloat, blue: CGFloat) -> Data {
        let context = CGContext(
            data: nil,
            width: 64,
            height: 40,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 40))
        let image = context.makeImage()!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}

@Suite("Export redaction")
struct ExportRedactionTests {
    @Test("redacted export drops chat and scrubs memory")
    func redacted() {
        let manifest = ExportManifest(
            bot: .init(name: "Scout", title: "t", description: "d", instructions: "i"),
            memory: [.init(path: "MEMORY.md", content: "token=sk-live-secret")],
            routines: [],
            files: [.init(path: "notes.txt", content: "/Users/me/vault")],
            history: [
                ThreadMessage(id: "m1", threadId: "t", seq: 1, role: .user, blocks: [.text("private chat")]),
            ]
        )
        let redacted = manifest.redacted()
        #expect(redacted.history.isEmpty)
        #expect(!redacted.memory[0].content.contains("sk-live-secret"))
        #expect(!redacted.files[0].content.contains("/Users/me"))
        #expect(manifest.history.count == 1)
    }
}

@Suite("Diagnostic breadcrumb scrub")
struct DiagnosticBreadcrumbTests {
    @Test("nested diagnostics redact secrets")
    func nested() {
        let value: [String: Any] = [
            "message": "Authorization: Bearer sk-test-abc",
            "data": ["path": "/Users/me/secret"],
            "crumbs": ["token=abc123", 12],
        ]
        let scrubbed = DiagnosticScrubber.redactAny(value) as? [String: Any]
        let message = scrubbed?["message"] as? String ?? ""
        #expect(message.contains("[redacted]"))
        let data = scrubbed?["data"] as? [String: Any]
        #expect((data?["path"] as? String)?.contains("[path]") == true)
        let crumbs = scrubbed?["crumbs"] as? [Any]
        #expect((crumbs?.first as? String)?.contains("[redacted]") == true)
    }
}
