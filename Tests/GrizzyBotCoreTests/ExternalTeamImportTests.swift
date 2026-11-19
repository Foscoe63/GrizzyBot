import Foundation
import GrizzyBotCore
import Testing

@Suite("External team import")
struct ExternalTeamImportTests {
    static let openMaus = """
    ---
    botmrr: 1
    id: 100x-marketing
    name: Launch a Measurable Campaign
    tagline: Find a sharp position.
    summary: A four-agent growth crew.
    requirements:
      apps:
        - slug: slack
          label: Slack
          reason: Share briefs.
          optional: true
    agents:
      - key: maya
        name: Maya
        title: Growth Lead
        description: Turn goals into bets.
        playbooks:
          - positioning-brief
      - key: lens
        name: Lens
        title: Growth Analyst
        description: Define measurement.
    chiefOfStaff: maya
    rooms:
      - key: campaign-room
        name: Campaign Room
        members:
          - maya
          - lens
        bulletin: Do not fabricate data.
    routines:
      - key: weekly
        name: Weekly review
        agent: lens
        prompt: Review experiments.
        schedule:
          type: daily
          time: 15:00
          weekdays:
            - 5
        enabledAfterInstall: false
    playbooks:
      - key: positioning-brief
        name: Positioning Brief
        instructions: Clarify the audience: who, why.
    ---

    # Launch
    """

    static let botteams = """
    ---
    slug: new-hire-ramp
    name: New-hire 30-60-90
    tagline: Turns a role into a plan.
    section: Workplace
    connectors:
      - Google Docs
    bot_roster:
      - name: Ramp planner
        persona: Writes a 30-60-90 from the role brief.
    rooms: []
    routines:
      - name: Ramp pass
        owner: Ramp planner
        schedule: Every weekday at 09:00
        prompt: Draft the plan. Do not send.
    suggest:
      - text: Never send mail.
        on: true
      - text: Ignore me.
        on: false
    ---

    Body.
    """

    @Test("an OpenMausBot team becomes bots, a room, a paused-style routine and a checklist")
    func openMausTeam() throws {
        let p = try TeamPackage.parse(markdown: Self.openMaus)
        #expect(p.name == "Launch a Measurable Campaign")
        #expect(p.bots.map(\.name) == ["Maya", "Lens"])
        #expect(p.bots[0].chiefOfStaff && !p.bots[1].chiefOfStaff)
        #expect(p.bots[0].instructions.contains("Clarify the audience: who, why."))
        #expect(p.bots[1].instructions.contains("Do not fabricate data."))
        #expect(p.rooms == [.init(name: "Campaign Room", members: ["Maya", "Lens"])])
        #expect(p.routines.first?.bot == "Lens")
        #expect(p.routines.first?.cron == "0 15 * * 5")
        #expect(p.connectors.first?.slug == "slack" && p.connectors.first?.required == false)
        #expect(p.departments.first?.bots == ["Maya", "Lens"])
    }

    @Test("a botteams bot keeps its persona and the switched-on rules")
    func botteamsBot() throws {
        let p = try TeamPackage.parse(markdown: Self.botteams)
        #expect(p.bots.count == 1)
        #expect(p.bots[0].instructions.contains("Never send mail."))
        #expect(!p.bots[0].instructions.contains("Ignore me."))
        #expect(p.routines.first?.cron == "0 9 * * 1-5")
        #expect(p.connectors.first?.name == "Google Docs")
    }

    @Test("schedule wording turns into cron, and unknown wording means no schedule")
    func schedules() {
        #expect(ExternalTeamImport.cron(fromText: "Every Monday at 8:30") == "30 8 * * 1")
        #expect(ExternalTeamImport.cron(fromText: "Daily at 6:00 PM") == "0 18 * * *")
        #expect(ExternalTeamImport.cron(fromText: "when a ticket arrives") == "")
    }

    @Test("GitHub page links resolve to raw files")
    func githubLinks() throws {
        let page = URL(string: "https://github.com/ellelion/botteams/blob/main/bots/new-hire-ramp.md")!
        #expect(GitHubSource.rawURL(for: page).absoluteString == "https://raw.githubusercontent.com/ellelion/botteams/main/bots/new-hire-ramp.md")
        #expect(GitHubSource.isRepoLink(URL(string: "https://github.com/milind-soni/openmausbot-teams")!))
        #expect(!GitHubSource.isRepoLink(page))
    }

    @Test("a file with no team in it is still rejected")
    func rejectsOther() {
        #expect(throws: TeamPackage.ParseError.noPackage) { try TeamPackage.parse(markdown: "# Just notes\n") }
    }
}
