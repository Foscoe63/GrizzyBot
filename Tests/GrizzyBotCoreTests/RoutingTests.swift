import Foundation
import GrizzyBotCore
import Testing

@Suite("Bot router")
struct BotRouterTests {
    static let ada = BotProfile(
        id: "ada", name: "Ada", title: "Coder", description: "Reads, edits and runs code in the project",
        instructions: "You write and review software. Prefer small commits and run the tests.",
        tools: ["read_file", "write_file", "edit_file", "shell", "list_files"], skills: ["coding"]
    )
    static let rae = BotProfile(
        id: "rae", name: "Rae", title: "Researcher", description: "Searches the web and writes cited briefs",
        instructions: "You find sources, compare them, and cite everything.",
        tools: ["web_search", "web_fetch", "remember"], skills: ["research"]
    )
    static let mo = BotProfile(
        id: "mo", name: "Mo", title: "Inbox and calendar", description: "Handles email and meetings",
        instructions: "You triage the inbox and schedule meetings.",
        tools: ["plugin_call", "destination_write"], skills: []
    )
    static let all = [ada, rae, mo]

    private func decide(_ text: String, _ t: BotRouter.Thresholds = .room) -> RouteDecision? {
        BotRouter.decide(message: text, candidates: Self.all, thresholds: t)
    }

    @Test("abilities come from the tools actually enabled")
    func abilities() {
        #expect(Self.ada.abilitySummary == "files, shell")
        #expect(Self.rae.has(.web) && !Self.rae.has(.shell))
        #expect(Self.mo.has(.mail))
    }

    @Test("clear requests go to the bot built for them")
    func routes() {
        #expect(decide("search the web for the latest news on Swift 6 and cite sources")?.botId == "rae")
        #expect(decide("refactor the parser file and run the tests")?.botId == "ada")
        #expect(decide("check my inbox and schedule a meeting with Sam")?.botId == "mo")
    }

    @Test("small talk and vague asks route nowhere")
    func noRoute() {
        for text in ["thanks!", "hi, how are you today?", "what do you think?", "ok", "can you help me with something"] {
            #expect(decide(text) == nil, "\(text)")
            #expect(decide(text, .dispatch) == nil, "\(text)")
        }
    }

    @Test("a request needing an ability the top bot lacks is never routed to it")
    func missingAbility() {
        // Needs the web; Ada has no web tools even though "write" matches her.
        let ranked = BotRouter.rank(message: "search the web and write it up", candidates: Self.all)
        #expect(ranked.first?.profile.id == "rae")
        #expect(ranked.first(where: { $0.profile.id == "ada" })?.missing.contains(.web) == true)
    }

    @Test("a tie is not a decision")
    func ties() {
        let twin = BotProfile(id: "rae2", name: "Rae Two", title: "Researcher", description: "Searches the web and writes cited briefs",
                              instructions: "You find sources, compare them, and cite everything.", tools: ["web_search"], skills: ["research"])
        let pair = [Self.rae, twin]
        #expect(BotRouter.decide(message: "search the web for otters", candidates: pair, thresholds: .room) == nil)
    }

    @Test("dispatch is stricter than a room")
    func strictness() {
        let text = "look up the latest news"
        let room = decide(text, .room)
        let dispatch = decide(text, .dispatch)
        if dispatch != nil { #expect(room != nil) }
    }

    @Test("ranking is deterministic and reasons are readable")
    func deterministic() {
        let a = BotRouter.rank(message: "run the tests on the code", candidates: Self.all).map(\.profile.id)
        let b = BotRouter.rank(message: "run the tests on the code", candidates: Self.all.reversed()).map(\.profile.id)
        #expect(a == b)
        let d = decide("refactor the parser file and run the tests")
        #expect(d?.reason.isEmpty == false)
        #expect(d?.source == .rules)
    }

    @Test("an explicit @mention beats scoring")
    func mention() {
        let d = BotRouter.mention(in: "@Mo please search the web", candidates: Self.all)
        #expect(d?.botId == "mo" && d?.source == .mention && d?.confidence == 1)
        #expect(BotRouter.mention(in: "mail me@mo.com", candidates: Self.all) == nil)
    }

    @Test("a request spanning several kinds of work is not swallowed by one specialist")
    func mixed() {
        #expect(decide("research the competitors and email me the result") == nil)
        #expect(decide("research the competitors and email me the result", .dispatch) == nil)
        #expect(decide("reply to Sam's email")?.botId == "mo")
    }

    @Test("a passing word in free-form instructions is not a speciality")
    func weakEvidence() {
        // Ada's instructions say "write"; nothing in who she is does.
        #expect(decide("write a short poem about autumn") == nil)
        #expect(decide("fix the bug in the login code")?.botId == "ada")
        #expect(decide("find sources on otters")?.botId == "rae")
    }

    @Test("a single candidate still has to earn the route")
    func single() {
        #expect(BotRouter.decide(message: "thanks", candidates: [Self.ada], thresholds: .room) == nil)
        #expect(BotRouter.decide(message: "refactor the code and run the tests", candidates: [Self.ada], thresholds: .room)?.botId == "ada")
    }
}

@Suite("Model router")
struct ModelRoutingTests2 {
    private let candidates = BotRouterTests.all

    @Test("the prompt lists every candidate with what it can do, and the message")
    func prompt() {
        let messages = ModelRouting.messages(for: "plan my week", candidates: candidates)
        let text = messages.compactMap(\.content).joined(separator: "\n")
        #expect(text.contains("id: ada") && text.contains("can: files, shell"))
        #expect(text.contains("plan my week"))
    }

    @Test("a valid JSON answer is accepted, by id or by name, even inside prose or a fence")
    func accepts() {
        #expect(ModelRouting.parse(#"{"bot":"rae","reason":"needs sources"}"#, candidates: candidates)?.botId == "rae")
        #expect(ModelRouting.parse("Sure!\n```json\n{\"bot\":\"Mo\",\"reason\":\"email\"}\n```", candidates: candidates)?.botId == "mo")
        let d = ModelRouting.parse(#"{"bot":"ada","reason":"code"}"#, candidates: candidates)
        #expect(d?.source == .model && d?.reason == "code")
    }

    @Test("null, unknown ids, malformed text and a bot outside the list are all 'no opinion'")
    func rejects() {
        #expect(ModelRouting.parse(#"{"bot":null}"#, candidates: candidates) == nil)
        #expect(ModelRouting.parse(#"{"bot":"ghost"}"#, candidates: candidates) == nil)
        #expect(ModelRouting.parse("I think Ada.", candidates: candidates) == nil)
        #expect(ModelRouting.parse("{not json}", candidates: candidates) == nil)
        #expect(ModelRouting.parse(#"{"bot":"rae"}"#, candidates: [BotRouterTests.ada]) == nil)
        #expect(ModelRouting.parse(#"{"bot":["rae"]}"#, candidates: candidates) == nil)
    }
}
