import Foundation
import GrizzyBotCore
import Testing

/// Builds throwaway model folders on disk so bundle validation and the layout
/// walkers are exercised against real files rather than a mock file system.
private struct Sandbox {
    let root: URL

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("grizzy-mlx-tests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func makeBundle(
        at relativePath: String,
        config: String = #"{"model_type":"qwen3","quantization":{"bits":4}}"#,
        tokenizer: String? = "tokenizer.json",
        weights: [String] = ["model.safetensors"],
        extras: [String] = []
    ) throws -> URL {
        let dir = root.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try config.write(to: dir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        if let tokenizer {
            try "{}".write(to: dir.appendingPathComponent(tokenizer), atomically: true, encoding: .utf8)
        }
        for weight in weights {
            try Data(repeating: 7, count: 1024).write(to: dir.appendingPathComponent(weight))
        }
        for extra in extras {
            try Data(repeating: 1, count: 8).write(to: dir.appendingPathComponent(extra))
        }
        return dir
    }
}

@Suite("MLX bundle validation")
struct MLXModelBundleTests {
    @Test("accepts config + tokenizer + safetensors")
    func acceptsCompleteBundle() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanup() }
        let dir = try sandbox.makeBundle(at: "good")

        let diagnostic = MLXModelBundle.diagnostic(at: dir, root: sandbox.root)
        #expect(diagnostic.isValid)
        #expect(diagnostic.reason == nil)
    }

    @Test("accepts BPE merges + vocab in place of tokenizer.json")
    func acceptsBPETokenizer() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanup() }
        let dir = try sandbox.makeBundle(at: "bpe", tokenizer: nil, extras: ["merges.txt", "vocab.json"])

        #expect(MLXModelBundle.diagnostic(at: dir, root: sandbox.root).isValid)
    }

    @Test("merges.txt alone is not a tokenizer")
    func rejectsMergesWithoutVocab() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanup() }
        let dir = try sandbox.makeBundle(at: "partial", tokenizer: nil, extras: ["merges.txt"])

        let diagnostic = MLXModelBundle.diagnostic(at: dir, root: sandbox.root)
        #expect(!diagnostic.isValid)
        #expect(diagnostic.reason == .missingTokenizer)
    }

    @Test("rejects a GGUF-only folder")
    func rejectsGGUFOnly() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanup() }
        let dir = try sandbox.makeBundle(at: "gguf", weights: [], extras: ["model.gguf"])

        let diagnostic = MLXModelBundle.diagnostic(at: dir, root: sandbox.root)
        #expect(!diagnostic.isValid)
        #expect(diagnostic.reason == .ggufOnly)
    }

    @Test("rejects a folder with no weights at all")
    func rejectsMissingWeights() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanup() }
        let dir = try sandbox.makeBundle(at: "empty", weights: [])

        #expect(MLXModelBundle.diagnostic(at: dir, root: sandbox.root).reason == .missingSafetensors)
    }

    @Test("rejects weights symlinked outside the scan root")
    func rejectsEscapingSymlink() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanup() }
        let outside = try Sandbox()
        defer { outside.cleanup() }

        let real = outside.root.appendingPathComponent("model.safetensors")
        try Data(repeating: 3, count: 64).write(to: real)

        let dir = try sandbox.makeBundle(at: "linked", weights: [])
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent("model.safetensors"),
            withDestinationURL: real
        )

        let diagnostic = MLXModelBundle.diagnostic(at: dir, root: sandbox.root)
        #expect(!diagnostic.isValid)
        #expect(diagnostic.reason == .symlinkEscapesRoot)
    }

    @Test("reads model type and quantization from config.json")
    func readsConfig() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanup() }
        let dir = try sandbox.makeBundle(at: "cfg")

        let config = MLXModelBundle.readConfig(at: dir)
        #expect(config.modelType == "qwen3")
        #expect(config.quantizationBits == 4)
    }

    @Test("containment compares whole path components")
    func containmentIsComponentwise() {
        let base = URL(fileURLWithPath: "/tmp/models", isDirectory: true)
        #expect(MLXModelBundle.isContained(URL(fileURLWithPath: "/tmp/models/a"), in: base))
        #expect(!MLXModelBundle.isContained(URL(fileURLWithPath: "/tmp/models-evil/a"), in: base))
    }
}

@Suite("MLX model locator")
struct MLXModelLocatorTests {
    @Test("finds publisher/repo bundles in a nested folder")
    func findsNestedBundles() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanup() }
        try sandbox.makeBundle(at: "mlx-community/Qwen3-4B-4bit")
        try sandbox.makeBundle(at: "lmstudio-community/Llama-3-8B")
        // A folder that is not a model at all must not appear or be reported.
        try FileManager.default.createDirectory(
            at: sandbox.root.appendingPathComponent("notes", isDirectory: true),
            withIntermediateDirectories: true
        )

        let report = MLXModelLocator.scan(roots: [
            MLXScanRoot(url: sandbox.root, source: "Custom model folder", layout: .nested),
        ])

        #expect(report.models.map(\.id) == ["lmstudio-community/Llama-3-8B", "mlx-community/Qwen3-4B-4bit"])
        #expect(report.models.allSatisfy { $0.source == "Custom model folder" })
        #expect(report.models.first?.quantizationBits == 4)
    }

    @Test("treats a folder that is itself a bundle as one model")
    func findsSingleBundleRoot() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanup() }
        let dir = try sandbox.makeBundle(at: "SoloModel")

        let report = MLXModelLocator.scan(roots: [
            MLXScanRoot(url: dir, source: "Custom model folder", layout: .nested),
        ])
        #expect(report.models.count == 1)
        #expect(report.models.first?.id == "SoloModel")
    }

    @Test("resolves the Hugging Face cache snapshot named by refs/main")
    func resolvesHuggingFaceCache() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanup() }

        let repo = "models--mlx-community--Qwen3-4B-4bit"
        try sandbox.makeBundle(at: "\(repo)/snapshots/aaa111")
        try sandbox.makeBundle(at: "\(repo)/snapshots/bbb222")
        let refs = sandbox.root.appendingPathComponent("\(repo)/refs", isDirectory: true)
        try FileManager.default.createDirectory(at: refs, withIntermediateDirectories: true)
        try "bbb222\n".write(to: refs.appendingPathComponent("main"), atomically: true, encoding: .utf8)

        let report = MLXModelLocator.scan(roots: [
            MLXScanRoot(url: sandbox.root, source: "Hugging Face cache", layout: .huggingFaceCache),
        ])

        #expect(report.models.count == 1)
        #expect(report.models.first?.id == "mlx-community/Qwen3-4B-4bit")
        #expect(report.models.first?.path.hasSuffix("snapshots/bbb222") == true)
    }

    @Test("reports an incomplete cache entry instead of dropping it silently")
    func reportsIncompleteCacheEntry() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanup() }
        try FileManager.default.createDirectory(
            at: sandbox.root.appendingPathComponent("models--org--repo", isDirectory: true),
            withIntermediateDirectories: true
        )

        let report = MLXModelLocator.scan(roots: [
            MLXScanRoot(url: sandbox.root, source: "Hugging Face cache", layout: .huggingFaceCache),
        ])
        #expect(report.models.isEmpty)
        #expect(report.skipped.first?.reason == .missingSnapshot)
    }

    @Test("the first root wins when two roots hold the same repo")
    func deduplicatesAcrossRoots() throws {
        let primary = try Sandbox()
        defer { primary.cleanup() }
        let secondary = try Sandbox()
        defer { secondary.cleanup() }
        try primary.makeBundle(at: "mlx-community/Qwen3-4B-4bit")
        try secondary.makeBundle(at: "mlx-community/Qwen3-4B-4bit")

        let report = MLXModelLocator.scan(roots: [
            MLXScanRoot(url: primary.root, source: "Downloaded in GrizzyBot", layout: .nested),
            MLXScanRoot(url: secondary.root, source: "LM Studio", layout: .nested),
        ])

        #expect(report.models.count == 1)
        #expect(report.models.first?.source == "Downloaded in GrizzyBot")
    }

    @Test("an absolute path resolves without a rescan, a deleted one does not")
    func resolvesByPath() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanup() }
        let dir = try sandbox.makeBundle(at: "solo")

        #expect(MLXModelLocator.bundleURL(forId: dir.path) != nil)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("config.json"))
        #expect(MLXModelLocator.bundleURL(forId: dir.path) == nil)
    }
}

@Suite("Hugging Face download set")
struct MLXHuggingFaceTests {
    @Test("keeps model files and drops repo extras")
    func filtersDownloadSet() {
        let files = [
            MLXHubFile(path: "config.json", size: 1),
            MLXHubFile(path: "tokenizer.json", size: 2),
            MLXHubFile(path: "model.safetensors", size: 3),
            MLXHubFile(path: "chat_template.jinja", size: 4),
            MLXHubFile(path: "README.md", size: 5),
            MLXHubFile(path: ".gitattributes", size: 6),
            MLXHubFile(path: "model.gguf", size: 7),
            MLXHubFile(path: "preview.png", size: 8),
        ]
        let kept = MLXHuggingFaceService.filterDownloadable(files).map(\.path).sorted()
        #expect(kept == ["chat_template.jinja", "config.json", "model.safetensors", "tokenizer.json"])
    }

    @Test("requires config, tokenizer and safetensors before downloading")
    func validatesRemoteBundle() {
        let complete = [
            MLXHubFile(path: "config.json", size: 1),
            MLXHubFile(path: "tokenizer.json", size: 1),
            MLXHubFile(path: "model-00001-of-00002.safetensors", size: 1),
        ]
        #expect(MLXHuggingFaceService.filesFormLoadableBundle(complete))

        let ggufOnly = [
            MLXHubFile(path: "config.json", size: 1),
            MLXHubFile(path: "tokenizer.json", size: 1),
            MLXHubFile(path: "model.gguf", size: 1),
        ]
        #expect(!MLXHuggingFaceService.filesFormLoadableBundle(ggufOnly))
    }

    @Test("rejects remote paths that would escape the model folder")
    func rejectsTraversal() {
        let base = URL(fileURLWithPath: "/tmp/models/org/repo", isDirectory: true)
        #expect(MLXHuggingFaceService.destinationURL(forRemotePath: "../../etc/passwd", under: base) == nil)
        #expect(MLXHuggingFaceService.destinationURL(forRemotePath: "/etc/passwd", under: base) == nil)
        #expect(MLXHuggingFaceService.normalizedRemotePath("a/../b") == nil)

        let nested = MLXHuggingFaceService.destinationURL(forRemotePath: "sub/model.safetensors", under: base)
        #expect(nested?.path == "/tmp/models/org/repo/sub/model.safetensors")
    }

    @Test("builds the resolve URL for a repo file")
    func buildsFileURL() {
        let url = MLXHuggingFaceService.fileURL(repoId: "mlx-community/Qwen3-4B-4bit", path: "config.json")
        #expect(url?.absoluteString == "https://huggingface.co/mlx-community/Qwen3-4B-4bit/resolve/main/config.json")
    }
}

@Suite("MLX tool-call parsing")
struct MLXToolCallParserTests {
    @Test("parses a Qwen/Hermes <tool_call> envelope")
    func parsesToolCallTag() {
        let raw = """
        Let me check that.
        <tool_call>
        {"name": "read_file", "arguments": {"path": "notes.txt"}}
        </tool_call>
        """
        let parsed = MLXToolCallParser.parse(raw)
        #expect(parsed.toolCalls.count == 1)
        #expect(parsed.toolCalls.first?.name == "read_file")
        #expect(parsed.toolCalls.first?.arguments == #"{"path":"notes.txt"}"#)
        #expect(parsed.text == "Let me check that.")
    }

    @Test("parses a Mistral [TOOL_CALLS] array")
    func parsesMistral() {
        let raw = #"[TOOL_CALLS] [{"name": "list_files", "arguments": {"dir": "."}}]"#
        let parsed = MLXToolCallParser.parse(raw)
        #expect(parsed.toolCalls.map(\.name) == ["list_files"])
        #expect(parsed.text.isEmpty)
    }

    @Test("parses the OpenAI function wrapper with string arguments")
    func parsesFunctionWrapper() {
        let raw = #"<tool_call>{"function": {"name": "web_search", "arguments": "{\"q\":\"mlx\"}"}}</tool_call>"#
        let parsed = MLXToolCallParser.parse(raw)
        #expect(parsed.toolCalls.first?.name == "web_search")
        #expect(parsed.toolCalls.first?.arguments == #"{"q":"mlx"}"#)
    }

    @Test("splits reasoning out of the answer")
    func splitsReasoning() {
        let parsed = MLXToolCallParser.parse("<think>weighing options</think>The answer is 4.")
        #expect(parsed.reasoning == "weighing options")
        #expect(parsed.text == "The answer is 4.")
    }

    @Test("keeps an unterminated think block out of the answer")
    func handlesTruncatedReasoning() {
        let parsed = MLXToolCallParser.parse("Sure.<think>still thinking when the cap hit")
        #expect(parsed.text == "Sure.")
        #expect(parsed.reasoning == "still thinking when the cap hit")
    }

    @Test("gives every call a distinct id")
    func numbersCalls() {
        let raw = """
        <tool_call>{"name": "a", "arguments": {}}</tool_call>
        <tool_call>{"name": "b", "arguments": {}}</tool_call>
        """
        let ids = MLXToolCallParser.parse(raw).toolCalls.map(\.id)
        #expect(ids == ["mlx_call_1", "mlx_call_2"])
    }

    @Test("plain prose stays prose")
    func leavesProseAlone() {
        let parsed = MLXToolCallParser.parse("I could call read_file, but I already know the answer: 42.")
        #expect(parsed.toolCalls.isEmpty)
        #expect(parsed.text.hasPrefix("I could call read_file"))
    }

    @Test("a brace inside a string value does not truncate the call")
    func handlesBracesInStrings() {
        let raw = #"<tool_call>{"name": "write_file", "arguments": {"content": "a } b"}}</tool_call>"#
        let parsed = MLXToolCallParser.parse(raw)
        #expect(parsed.toolCalls.count == 1)
        #expect(parsed.toolCalls.first?.arguments.contains("a } b") == true)
    }
}

@Suite("Local MLX provider wiring")
struct MLXProviderWiringTests {
    @Test("appears in the provider rail as a local provider")
    func appearsInCatalog() {
        let entry = ModelCatalog.providers.first { $0.provider == MLXProvider.id }
        #expect(entry != nil)
        #expect(entry?.kind == .local)
        #expect(entry?.supportsBaseUrl == false)
        #expect(ModelCatalog.hint(for: entry!) == "Runs in app")
    }

    @Test("is not treated as a base-URL provider")
    func isNotBaseURLConfigured() {
        #expect(!ModelCatalog.usesCustomBase(MLXProvider.id))
        #expect(!LocalProviders.isLocal(MLXProvider.id))
    }

    @Test("routes to an in-process endpoint carrying the bundle path")
    func routesInProcess() throws {
        let endpoint = try LLMRouting.endpoint(
            provider: MLXProvider.id,
            modelId: "/Users/someone/Models/Qwen3-4B-4bit",
            apiKey: nil,
            baseUrl: nil
        )
        #expect(endpoint.provider == MLXProvider.id)
        #expect(endpoint.model == "/Users/someone/Models/Qwen3-4B-4bit")
        #expect(endpoint.baseURL == MLXProvider.inProcessBaseURL)
    }

    @Test("needs no API key to be runnable on Apple Silicon")
    func runnableWithoutKey() {
        #expect(
            LLMRouting.canRun(
                provider: MLXProvider.id,
                apiKey: nil,
                baseUrl: nil,
                injectedClient: false
            ) == MLXProvider.isSupportedHardware
        )
    }

    @Test("fails with a clear message when the selected bundle is gone")
    func reportsMissingBundle() async throws {
        let client = MLXChatClient(generator: MLXUnavailableGenerator(reason: "unused"))
        let request = ChatCompletionRequest(
            endpoint: ModelEndpoint(
                provider: MLXProvider.id,
                model: "/nonexistent/model/folder",
                baseURL: MLXProvider.inProcessBaseURL,
                apiKey: "local"
            ),
            messages: [.user("hi")]
        )

        await #expect(throws: LLMError.self) {
            _ = try await client.complete(request)
        }
    }
}

/// Drives `MLXChatClient` without MLX linked, so the parsing and streaming
/// contract is covered on every machine.
private struct StubGenerator: MLXTextGenerating {
    let output: String

    func generate(
        _ request: MLXGenerationRequest,
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws -> MLXGenerationResult {
        // Feed it a character at a time so the stream filter is exercised the
        // way a real token stream exercises it.
        for character in output {
            onDelta(String(character))
        }
        return MLXGenerationResult(
            text: output,
            promptTokens: 11,
            generatedTokens: 22,
            finishReason: nil
        )
    }

    func unload() async {}
}

@Suite("MLX chat client")
struct MLXChatClientTests {
    private func bundle() throws -> (URL, () -> Void) {
        let sandbox = try Sandbox()
        let dir = try sandbox.makeBundle(at: "solo")
        return (dir, sandbox.cleanup)
    }

    @Test("returns parsed text, tool calls and token counts")
    func completesThroughGenerator() async throws {
        guard MLXProvider.isSupportedHardware else { return }
        let (dir, cleanup) = try bundle()
        defer { cleanup() }

        let raw = "<think>hmm</think>Reading it now.<tool_call>{\"name\":\"read_file\",\"arguments\":{\"path\":\"a.txt\"}}</tool_call>"
        let client = MLXChatClient(generator: StubGenerator(output: raw))
        let response = try await client.complete(
            ChatCompletionRequest(
                endpoint: ModelEndpoint(
                    provider: MLXProvider.id,
                    model: dir.path,
                    baseURL: MLXProvider.inProcessBaseURL,
                    apiKey: "local"
                ),
                messages: [.user("read a.txt")]
            )
        )

        #expect(response.text == "Reading it now.")
        #expect(response.toolCalls.map(\.name) == ["read_file"])
        #expect(response.inputTokens == 11)
        #expect(response.outputTokens == 22)
        #expect(response.finishReason == "tool_calls")
    }

    @Test("streams only visible prose, never reasoning or tool envelopes")
    func streamsVisibleTextOnly() async throws {
        guard MLXProvider.isSupportedHardware else { return }
        let (dir, cleanup) = try bundle()
        defer { cleanup() }

        let raw = "<think>secret</think>Hello there.<tool_call>{\"name\":\"a\",\"arguments\":{}}</tool_call>"
        let client = MLXChatClient(generator: StubGenerator(output: raw))

        let collected = Collector()
        _ = try await client.stream(
            ChatCompletionRequest(
                endpoint: ModelEndpoint(
                    provider: MLXProvider.id,
                    model: dir.path,
                    baseURL: MLXProvider.inProcessBaseURL,
                    apiKey: "local"
                ),
                messages: [.user("hi")]
            ),
            onDelta: { collected.append($0) }
        )

        let streamed = collected.value
        #expect(!streamed.contains("secret"))
        #expect(!streamed.contains("tool_call"))
        #expect(streamed.contains("Hello there."))
    }
}

private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""

    func append(_ text: String) {
        lock.lock()
        buffer += text
        lock.unlock()
    }

    var value: String {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }
}
