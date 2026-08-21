import Foundation
import GrizzyBotCore
import Testing

@Suite("Slash commands")
struct SlashCommandTests {
    @Test("parses skill name and argument")
    func parseSkill() {
        let parsed = SlashCommand.parse("/research summarize otters")
        #expect(parsed?.name == "research")
        #expect(parsed?.argument == "summarize otters")
        #expect(SlashCommand.parse("hello") == nil)
        #expect(SlashCommand.parse("/")?.name == "help")
    }

    @Test("resolves enabled skills and help")
    func resolve() {
        let skills = [BundledSkills.research, BundledSkills.coding]
        if case .skill(let skill, let prompt) = SlashCommand.resolve("/research cite sources", skills: skills) {
            #expect(skill.id == "research")
            #expect(prompt == "cite sources")
        } else {
            Issue.record("expected skill")
        }
        if case .skill(_, let bare) = SlashCommand.resolve("/coding", skills: skills) {
            #expect(bare.contains("coding"))
        } else {
            Issue.record("expected bare skill")
        }
        if case .help(let listed) = SlashCommand.resolve("/help", skills: skills) {
            #expect(listed.count == 2)
        } else {
            Issue.record("expected help")
        }
        if case .unknown(let name) = SlashCommand.resolve("/nope", skills: skills) {
            #expect(name == "nope")
        } else {
            Issue.record("expected unknown")
        }
        if case .plain(let text) = SlashCommand.resolve("no slash", skills: skills) {
            #expect(text == "no slash")
        } else {
            Issue.record("expected plain")
        }
    }

    @Test("suggestions filter by prefix before an argument")
    func suggestions() {
        let skills = BundledSkills.all
        let all = SlashCommand.suggestions(draft: "/", skills: skills)
        #expect(all.count == min(8, skills.count))
        let research = SlashCommand.suggestions(draft: "/re", skills: skills)
        #expect(research.map(\.id) == ["research"])
        #expect(SlashCommand.suggestions(draft: "/research more", skills: skills).isEmpty)
    }

    @Test("send /help replies locally without a run")
    @MainActor
    func sendHelp() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("slash-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = AppStore(dataDirectory: dir, delayScale: 0.01)
        store.pluginClient = AlwaysAllowPlugins()
        let bot = store.createBot(name: "Slashy")
        store.send(botId: bot.id, text: "/help")
        let messages = store.threads[bot.id]?.messages ?? []
        #expect(messages.count == 2)
        #expect(messages[0].role == .user)
        #expect(messages[1].role == .bot)
        #expect(messages[1].firstText.contains("/research"))
        #expect(store.threads[bot.id]?.run == nil)
    }
}
