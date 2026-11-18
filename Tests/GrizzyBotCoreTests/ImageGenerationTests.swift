import Foundation
import GrizzyBotCore
import Testing

@Suite("Image generation")
struct ImageGenerationTests {
    @Test("file names are safe and unique per variation")
    func names() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(ImageGeneration.fileName(for: "A red fox / in snow!", now: t) == "images/a-red-fox-in-snow-1800000000.png")
        #expect(ImageGeneration.fileName(for: "x", index: 2, now: t).hasSuffix("-1800000000-2.png"))
        #expect(ImageGeneration.fileName(for: "!!!", now: t).hasPrefix("images/image-"))
    }

    @Test("an empty prompt, or no Apple Intelligence, fails with a plain message")
    func failures() async {
        await #expect(throws: ImageGeneration.Failure.self) { try await ImageGeneration.generate(prompt: "  ") }
        if !ImageGeneration.isAvailable {
            await #expect(throws: ImageGeneration.Failure.unavailable) { try await ImageGeneration.generate(prompt: "a fox") }
        }
    }
}
