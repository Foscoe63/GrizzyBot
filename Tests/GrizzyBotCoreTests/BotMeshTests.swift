import Foundation
import Testing
import GrizzyBotCore

@Suite("Bot mesh")
struct BotMeshTests {
    private func bot(_ name: String) -> Bot {
        Bot(id: name.lowercased().replacingOccurrences(of: " ", with: "-"), name: name, color: "#3B82F6", threadId: Ids.new())
    }

    private var members: [Bot] { [bot("Ada"), bot("Research Bot"), bot("Grace")] }

    @Test("@name picks that member, in order of mention")
    func mentionOrder() {
        let ids = GroupMentions.parse("@Grace then @ada please", members: members).botIds
        #expect(ids == ["grace", "ada"])
    }

    @Test("names with spaces match collapsed, hyphenated and first-word handles")
    func spacedNames() {
        for text in ["@ResearchBot hi", "@research-bot hi", "@research hi"] {
            #expect(GroupMentions.parse(text, members: members).botIds == ["research-bot"], "\(text)")
        }
    }

    @Test("trailing punctuation is ignored and emails are not mentions")
    func punctuationAndEmail() {
        #expect(GroupMentions.parse("thanks @ada, and mail me@grace.com", members: members).botIds == ["ada"])
        #expect(GroupMentions.parse("(@grace)", members: members).botIds == ["grace"])
    }

    @Test("@everyone and @all select the whole room")
    func everyone() {
        #expect(GroupMentions.responders(for: "@all thoughts?", members: members)?.count == 3)
        #expect(GroupMentions.responders(for: "@everyone", members: members)?.count == 3)
    }

    @Test("no mention returns nil so the room default applies; unknown handles are ignored")
    func noMention() {
        #expect(GroupMentions.responders(for: "hello room", members: members) == nil)
        #expect(GroupMentions.responders(for: "@nobody hi", members: members) == nil)
    }

    @Test("old workspaces decode: new Bot and message fields default to nil")
    func backwardCompatible() throws {
        let bot = try JSONDecoder().decode(
            Bot.self,
            from: Data(##"{"id":"a","name":"A","color":"#fff","threadId":"t"}"##.utf8)
        )
        #expect(bot.avatarShape == nil && bot.avatarImageRev == nil)
        let ws = try JSONDecoder().decode(UserWorkspace.self, from: Data("{}".utf8))
        #expect(ws.botChat.isEmpty)
    }

    @Test("avatar shape falls back to circle for unknown values")
    func shapeFallback() {
        #expect(BotAvatarShape.resolve(nil) == .circle)
        #expect(BotAvatarShape.resolve("hexagon") == .hexagon)
        #expect(BotAvatarShape.resolve("blob") == .circle)
    }
}
