import Foundation
import Testing
@testable import GrizzyBotCore

@Suite("Questions with choices")
struct AskChoiceTests {
    @Test("choices are read from an array, a JSON string, or a separated string, kept short and unique")
    func parsing() {
        #expect(AgentSessionTools.parseChoices(.array([.string("Red"), .string("Blue")])) == ["Red", "Blue"])
        #expect(AgentSessionTools.parseChoices(.string(#"["Red","Blue"]"#)) == ["Red", "Blue"])
        #expect(AgentSessionTools.parseChoices(.string("Red | Blue, light | Green")) == ["Red", "Blue, light", "Green"])
        #expect(AgentSessionTools.parseChoices(.string("Red; Blue")) == ["Red", "Blue"])
        #expect(AgentSessionTools.parseChoices(.string("Red, Blue")) == ["Red", "Blue"])
        #expect(AgentSessionTools.parseChoices(.string("Red\nBlue")) == ["Red", "Blue"])
        #expect(AgentSessionTools.parseChoices(.string("Red | red | RED | ")) == ["Red"])
        #expect(AgentSessionTools.parseChoices(nil).isEmpty)
        let many = AgentSessionTools.parseChoices(.string((1...20).map { "Option \($0)" }.joined(separator: "|")))
        #expect(many.count == AgentSessionTools.maxChoices)
        let long = AgentSessionTools.parseChoices(.array([.string(String(repeating: "x", count: 500)), .string("b")]))
        #expect(long[0].count == AgentSessionTools.maxChoiceChars)
    }

    @Test("two or more options make a card of buttons that pauses the run")
    func card() throws {
        let result = AgentSessionTools.handleClarify(question: "Which one?", detail: "For the report", options: ["Red", "Blue", "Green"])
        #expect(result.pause == .waitingInput)
        guard case .choice(let question, let subtitle, let options)? = result.blocks.first else {
            Issue.record("expected a choice card")
            return
        }
        #expect(question == "Which one?" && subtitle == "For the report")
        #expect(options.map(\.label) == ["Red", "Blue", "Green"])
        #expect(options.map(\.letter) == ["A", "B", "C"])
        #expect(Set(options.map(\.id)).count == 3)
    }

    @Test("without enough options it is the plain question it always was")
    func plain() {
        for options in [[], ["Only one"]] {
            let result = AgentSessionTools.handleClarify(question: "Which?", options: options)
            #expect(result.pause == .waitingInput)
            if case .ask(let text, let detail)? = result.blocks.first { #expect(text == "Which?" && detail == nil) } else { Issue.record("expected an ask") }
        }
        #expect(AgentSessionTools.handleClarify(question: "  ").pause == nil)
    }

    @Test("the clarify tool offers options")
    func schema() throws {
        let tool = try #require(AgentToolCatalog.chatTools(enabledIds: ["clarify"], includeDelegation: false).first { $0.function.name == "clarify" })
        let text = String(data: try JSONEncoder().encode(tool.function.parameters), encoding: .utf8) ?? ""
        #expect(text.contains("options") && text.contains("detail"))
    }
}
