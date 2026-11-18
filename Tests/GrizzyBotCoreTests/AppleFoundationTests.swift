import Foundation
import GrizzyBotCore
import Testing

@Suite("Apple Foundation provider")
struct AppleFoundationTests {
    @Test("identified by id, and unavailable hardware says so instead of crashing")
    func basics() async {
        #expect(AppleFoundationProvider.isProvider("apple-foundation"))
        #expect(!AppleFoundationProvider.isProvider("openai"))
        if !AppleFoundationProvider.isAvailable {
            let endpoint = ModelEndpoint(provider: "apple-foundation", model: AppleFoundationProvider.modelId, baseURL: "x", apiKey: "local")
            let request = ChatCompletionRequest(endpoint: endpoint, messages: [ChatMessage(role: "user", content: "hi")])
            await #expect(throws: (any Error).self) { try await AppleFoundationClient.shared.complete(request) }
        }
        #expect(AppleFoundationProvider.catalogEntry().kind == .local)
    }
}
