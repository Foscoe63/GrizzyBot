import Foundation

/// AionUi-style assistant presets: name, instructions, default skills/tools.
public struct BotTemplate: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var title: String
    public var blurb: String
    public var instructions: String
    public var skillIds: [String]
    public var toolIds: [String]

    public init(
        id: String,
        name: String,
        title: String,
        blurb: String,
        instructions: String,
        skillIds: [String],
        toolIds: [String] = AgentToolCatalog.builtinIds
    ) {
        self.id = id
        self.name = name
        self.title = title
        self.blurb = blurb
        self.instructions = instructions
        self.skillIds = skillIds
        self.toolIds = toolIds
    }
}

public enum BotTemplates {
    public static let all: [BotTemplate] = [coworker, researcher, writer, coder, desktopOperator]

    public static let coworker = BotTemplate(
        id: "coworker",
        name: "Coworker",
        title: "General coworker",
        blurb: "Files, search, memory, and the computer — pick this if you're not sure.",
        instructions: """
        You are a general coworker on this Mac. Use skills when they fit: research, office-docs, coding, browser, memory.
        Prefer tools over guessing. Write real files when the user wants a deliverable.
        """,
        skillIds: BundledSkills.ids
    )

    public static let researcher = BotTemplate(
        id: "researcher",
        name: "Researcher",
        title: "Research & briefs",
        blurb: "Web search, cited notes, and saved briefs.",
        instructions: """
        You research. Always load the research skill first.
        Search, fetch sources, cite URLs, and write briefs under notes/ when asked for a file.
        """,
        skillIds: ["research", "memory", "office-docs"]
    )

    public static let writer = BotTemplate(
        id: "writer",
        name: "Writer",
        title: "Docs & drafts",
        blurb: "Reports, outlines, CSV tables, HTML slides.",
        instructions: """
        You produce documents. Load office-docs before writing a file.
        Default to markdown reports, CSV tables, and HTML slide decks in notes/.
        Match the user's tone from memory when it exists.
        """,
        skillIds: ["office-docs", "memory", "research"]
    )

    public static let coder = BotTemplate(
        id: "coder",
        name: "Coder",
        title: "Code in the bot home",
        blurb: "Read, edit, and run code inside this bot's files.",
        instructions: """
        You write and run code in your bot home. Load the coding skill first.
        Read before you edit. Run commands with shell. Summarize the diff.
        """,
        skillIds: ["coding", "memory"]
    )

    public static let desktopOperator = BotTemplate(
        id: "operator",
        name: "Operator",
        title: "Drive this Mac",
        blurb: "Open sites, screenshot, click, type, hand over for login.",
        instructions: """
        You operate the live computer. Load the browser skill first.
        Screenshot before every click. Take over when a human must sign in.
        """,
        skillIds: ["browser", "memory"]
    )
}
