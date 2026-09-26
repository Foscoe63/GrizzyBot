import Foundation
import GrizzyBotCore
import Testing

@Suite("LocalProviders")
struct LocalProvidersTests {
    @Test("exposes Ollama, LM Studio, vMLX, oMLX, and Splash")
    func catalog() {
        let ids = LocalProviders.catalogEntries().map(\.provider)
        #expect(ids == ["ollama", "lmstudio", "vmlx", "omlx", "splash"])
        #expect(LocalProviders.isLocal("ollama"))
        #expect(!LocalProviders.isLocal("openrouter"))
        #expect(ModelCatalog.providers.first?.kind == .local)
        #expect(ModelCatalog.entries.contains(where: { $0.provider == ModelCatalog.openaiCompatibleProvider }))
        #expect(ModelCatalog.usesCustomBase("openai-compatible"))
        #expect(ModelCatalog.usesCustomBase("lmstudio"))
        #expect(!ModelCatalog.usesCustomBase("openrouter"))
    }

    @Test("normalizes base URLs to /v1")
    func normalize() throws {
        #expect(try LocalProviders.normalizeBaseUrl("http://192.168.1.40:11434") == "http://192.168.1.40:11434/v1")
        #expect(try LocalProviders.normalizeBaseUrl("http://127.0.0.1:1234/v1/") == "http://127.0.0.1:1234/v1")
        #expect(try LocalProviders.normalizeBaseUrl("192.168.1.5:8000", provider: "vmlx") == "http://192.168.1.5:8000/v1")
        #expect(try LocalProviders.normalizeBaseUrl("", provider: "ollama") == "http://127.0.0.1:11434/v1")
    }

    @Test("accepts private LAN hosts only")
    func privateHosts() throws {
        _ = try LocalProviders.assertPrivateProviderUrl("http://10.0.0.2:11434/v1")
        _ = try LocalProviders.assertPrivateProviderUrl("http://192.168.1.40:1234/v1")
        _ = try LocalProviders.assertPrivateProviderUrl("http://studio.local:1234/v1")
        #expect(throws: LocalProviderError.self) {
            try LocalProviders.assertPrivateProviderUrl("http://example.com/v1")
        }
        #expect(LocalProviders.isPrivateOrLoopbackIP("172.20.1.5"))
        #expect(!LocalProviders.isPrivateOrLoopbackIP("8.8.8.8"))
        _ = try LocalProviders.assertProviderUrl("https://api.example.com/v1", requirePrivateHost: false)
        #expect(throws: LocalProviderError.self) {
            try LocalProviders.assertProviderUrl("https://api.example.com/v1", requirePrivateHost: true)
        }
    }

    @Test("parses OpenAI-compatible model list JSON")
    func parseModels() throws {
        let json = Data(#"{"data":[{"id":"llama3.2"},{"id":"qwen2.5","name":"Qwen 2.5"}]}"#.utf8)
        let models = try LocalProviders.parseModelsJSON(json)
        #expect(models.map(\.id) == ["llama3.2", "qwen2.5"])
        #expect(models[1].label == "Qwen 2.5")
    }

    @Test("skips non-LLM rows and parses LM Studio native v1 models")
    func lmStudioModels() throws {
        let json = Data(
            #"{"data":[{"id":"embed-model","type":"embedding"},{"id":"qwen-local","type":"llm","name":"Qwen Local"}]}"#.utf8
        )
        let models = try LocalProviders.parseModelsJSON(json)
        #expect(models.map(\.id) == ["qwen-local"])

        let native = Data(
            #"{"models":[{"key":"google/gemma","display_name":"Gemma","type":"llm"},{"key":"nomic-embed","type":"embedding"}]}"#.utf8
        )
        let nativeModels = try LocalProviders.parseModelsJSON(native)
        #expect(nativeModels.map(\.id) == ["google/gemma"])
        #expect(nativeModels[0].label == "Gemma")
    }
}

@Suite("SplashModelLocator")
struct SplashModelLocatorTests {
    @Test("reads the quantization out of a GGUF file name")
    func variants() {
        #expect(SplashModelLocator.ggufVariant(fromFileName: "Qwen3.8-27B-UD-Q4_K_M.gguf") == "UD-Q4_K_M")
        #expect(SplashModelLocator.ggufVariant(fromFileName: "Qwen3.8-27B-Q8_0.gguf") == "Q8_0")
        #expect(SplashModelLocator.ggufVariant(fromFileName: "Qwen3.8-27B-UD-Q4_K_M-00001-of-00002.gguf") == "UD-Q4_K_M")
        #expect(SplashModelLocator.ggufVariant(fromFileName: "mmproj-F16.gguf") == nil)
        #expect(SplashModelLocator.ggufVariant(fromFileName: "notes.txt") == nil)
    }

    @Test("finds Splash models in an LM Studio style folder and ignores others")
    func scan() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("splash-scan-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func make(_ path: String, _ files: [String]) throws {
            let dir = root.appendingPathComponent(path, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for f in files { try Data("x".utf8).write(to: dir.appendingPathComponent(f)) }
        }
        try make("incoai/Qwen3.8-27B-Splash", ["config.json", "model.safetensors"])
        try make("unsloth/Qwen3.8-27B-GGUF", ["Qwen3.8-27B-UD-Q4_K_M.gguf", "mmproj-F16.gguf"])
        try make("meta/llama-3", ["config.json", "model.safetensors"])

        let report = SplashModelLocator.scan(roots: [MLXScanRoot(url: root, source: "LM Studio", layout: .nested)])
        #expect(report.models.map(\.id) == ["incoai/Qwen3.8-27B-Splash", "unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_M"])
        #expect(report.models.map(\.format) == [.splashPackage, .gguf])
    }
}
