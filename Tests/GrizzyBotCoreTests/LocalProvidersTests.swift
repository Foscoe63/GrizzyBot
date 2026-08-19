import Foundation
import GrizzyBotCore
import Testing

@Suite("LocalProviders")
struct LocalProvidersTests {
    @Test("exposes Ollama, LM Studio, vMLX, and oMLX")
    func catalog() {
        let ids = LocalProviders.catalogEntries().map(\.provider)
        #expect(ids == ["ollama", "lmstudio", "vmlx", "omlx"])
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
