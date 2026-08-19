import Foundation
import GrizzyBotCore
import Testing

@Suite("Model provider profiles")
struct ModelProviderProfileTests {
    @Test("each provider keeps its own settings when another is saved")
    @MainActor
    func isolatedProfiles() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gb-providers-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = AppStore(dataDirectory: dir, delayScale: 0.01)

        store.saveModelSelection(
            provider: "lmstudio",
            modelId: "qwen3-coder-next-mlx",
            apiKey: nil,
            baseUrl: "http://192.168.1.176:1234/v1",
            models: [LocalModelRef(id: "qwen3-coder-next-mlx")]
        )
        store.saveModelSelection(
            provider: "openrouter",
            modelId: "deepseek/deepseek-v4-flash-0731",
            apiKey: "sk-openrouter-key",
            baseUrl: nil,
            models: []
        )

        let lm = store.modelProviderSettings(for: "lmstudio")
        #expect(lm.modelId == "qwen3-coder-next-mlx")
        #expect(lm.baseUrl == "http://192.168.1.176:1234/v1")
        #expect(lm.fetchedModels.map(\.id) == ["qwen3-coder-next-mlx"])
        #expect((lm.apiKey ?? "").isEmpty)

        let or = store.modelProviderSettings(for: "openrouter")
        #expect(or.modelId == "deepseek/deepseek-v4-flash-0731")
        #expect(or.apiKey == "sk-openrouter-key")

        store.updateModelProviderDraft(
            provider: "lmstudio",
            modelId: "other-model",
            apiKey: nil,
            baseUrl: "http://192.168.1.176:1234/v1",
            models: []
        )
        #expect(store.modelProviderSettings(for: "openrouter").apiKey == "sk-openrouter-key")
    }

    @Test("legacy single-provider workspace migrates into profiles")
    func legacyMigration() {
        var ws = UserWorkspace()
        ws.modelProvider = "ollama"
        ws.modelId = "llama3"
        ws.modelBaseUrl = "http://127.0.0.1:11434/v1"
        ws.fetchedModels = [LocalModelRef(id: "llama3")]
        ws.apiKey = "legacy-key"

        let profiles = ModelProviderProfiles.migrateProfiles(from: ws)
        let creds = ModelProviderProfiles.migrateCredentials(from: ws, existing: [:])
        #expect(profiles["ollama"]?.modelId == "llama3")
        #expect(profiles["ollama"]?.baseUrl == "http://127.0.0.1:11434/v1")
        #expect(creds["ollama"]?.apiKey == "legacy-key")
        #expect(profiles["ollama"]?.enabled == true)
    }

    @Test("enabled toggle is independent and only enabled providers contribute models")
    @MainActor
    func enableToggle() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gb-enabled-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = AppStore(dataDirectory: dir, delayScale: 0.01)

        store.saveModelSelection(
            provider: "lmstudio",
            modelId: "qwen-local",
            apiKey: nil,
            baseUrl: "http://127.0.0.1:1234/v1",
            models: [LocalModelRef(id: "qwen-local")]
        )
        store.saveModelSelection(
            provider: "openai-compatible",
            modelId: "gpt-oss",
            apiKey: "sk-compat",
            baseUrl: "https://llm.example.com/v1",
            models: [LocalModelRef(id: "gpt-oss")]
        )
        store.setProviderEnabled("lmstudio", enabled: true)
        store.setProviderEnabled("openai-compatible", enabled: true)
        store.setProviderEnabled("openrouter", enabled: false)

        #expect(store.isProviderEnabled("lmstudio"))
        #expect(store.isProviderEnabled("openai-compatible"))
        #expect(!store.isProviderEnabled("openrouter"))

        let sources = store.enabledModelSources()
        #expect(sources.map(\.provider).contains("lmstudio"))
        #expect(sources.map(\.provider).contains("openai-compatible"))
        #expect(!sources.map(\.provider).contains("openrouter"))

        store.setProviderEnabled("openai-compatible", enabled: false)
        #expect(!store.enabledModelSources().map(\.provider).contains("openai-compatible"))
        #expect(store.modelProviderSettings(for: "openai-compatible").apiKey == "sk-compat")
        #expect(store.modelProviderSettings(for: "openai-compatible").baseUrl == "https://llm.example.com/v1")
    }
}
