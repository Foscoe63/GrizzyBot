import Foundation
import GrizzyBotCore
import GrizzyBotMLX
import Testing

/// End-to-end proof of the Local MLX path: download a real model from Hugging
/// Face, discover it with the locator, and generate text with it on the GPU.
///
/// Off by default — it pulls hundreds of megabytes and needs Apple Silicon.
/// Run it with:
///
///     GRIZZYBOT_MLX_INTEGRATION=1 swift test --filter MLXIntegration
///
@Suite("MLX integration", .serialized)
struct MLXIntegrationTests {
    /// Put MLX's Metal shaders where the test binary can find them, and take
    /// them away again. Under `swift test` the binary sits in
    /// `<name>.xctest/Contents/MacOS`, which is both the only directory MLX
    /// searches first and the one place `codesign` refuses to accept a
    /// non-executable — leaving the file behind makes the *next* build of this
    /// test bundle fail to sign.
    private func withMetallib<T>(_ body: () async throws -> T) async rethrows -> T {
        let staged = MLXMetallibBootstrap.stageBesideExecutable()
        defer {
            if let staged { try? FileManager.default.removeItem(at: staged) }
        }
        return try await body()
    }

    /// Small enough to download quickly, real enough to exercise the tokenizer,
    /// chat template, and Metal kernels.
    static let repoId = "mlx-community/Qwen2.5-0.5B-Instruct-4bit"

    static var enabled: Bool {
        ProcessInfo.processInfo.environment["GRIZZYBOT_MLX_INTEGRATION"] == "1"
            && MLXProvider.isSupportedHardware
    }

    @Test("downloads, discovers and runs a real MLX model")
    func endToEnd() async throws {
        guard Self.enabled else { return }
        try await withMetallib {
        GrizzyBotMLXBootstrap.install()
        #expect(MLXRuntime.isAvailable)

        // 1. Download (a no-op when the bundle is already complete on disk).
        let bundle = try await MLXModelDownloader.shared.download(repoId: Self.repoId)
        #expect(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("config.json").path))

        // 2. The locator must find what the downloader just wrote.
        let report = MLXModelLocator.scan(roots: MLXModelLocator.defaultRoots())
        let found = report.models.first { $0.id.caseInsensitiveCompare(Self.repoId) == .orderedSame }
        #expect(found != nil, "the downloaded model was not discovered by a scan")
        #expect(found?.source == "Downloaded in GrizzyBot")
        #expect((found?.sizeBytes ?? 0) > 0)

        // 3. Generate through the same client a chat turn uses.
        let client = MLXChatClient()
        let response = try await client.complete(
            ChatCompletionRequest(
                endpoint: ModelEndpoint(
                    provider: MLXProvider.id,
                    model: found?.path ?? bundle.path,
                    baseURL: MLXProvider.inProcessBaseURL,
                    apiKey: "local"
                ),
                messages: [
                    .system("You are terse. Answer in one short sentence."),
                    .user("What is the capital of France?"),
                ]
            )
        )

        #expect(!response.text.isEmpty, "the model produced no visible text")
        #expect(response.text.lowercased().contains("paris"))
        #expect(response.outputTokens > 0)
        #expect(response.inputTokens > 0)

        await MLXLocalGenerator.shared.unload()
        }
    }

    @Test("streams deltas while generating")
    func streams() async throws {
        guard Self.enabled else { return }
        try await withMetallib {
        GrizzyBotMLXBootstrap.install()

        guard let bundle = MLXModelLocator.bundleURL(forId: Self.repoId) else {
            Issue.record("run the end-to-end test first to download the model")
            return
        }

        let collected = Collector()
        let client = MLXChatClient()
        let response = try await client.stream(
            ChatCompletionRequest(
                endpoint: ModelEndpoint(
                    provider: MLXProvider.id,
                    model: bundle.path,
                    baseURL: MLXProvider.inProcessBaseURL,
                    apiKey: "local"
                ),
                messages: [.user("Count from one to five.")]
            ),
            onDelta: { collected.append($0) }
        )

        #expect(!collected.value.isEmpty, "no deltas were streamed")
        #expect(!response.text.isEmpty)

        await MLXLocalGenerator.shared.unload()
        }
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
