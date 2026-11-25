import Foundation

// Teach by demonstration: the person drives the in-app browser, GrizzyBot writes the steps down as a skill proposal.
extension AppStore {
    /// Why a bot's computer cannot be recorded, or nil. Only the in-app browser can report what a person clicks.
    public func demoRecordingRefusal(botId: String) -> String? {
        guard let bot = bots.first(where: { $0.id == botId }) else { return "No such bot." }
        if demoRecordingBotId != nil { return "A recording is already running." }
        switch resolvedComputerMode(for: bot) {
        case .thisMac: return "Teaching works in the in-app browser. On This Mac, GrizzyBot cannot see what you click."
        case .privateDesktop: return "A Private desktop cannot be driven by a person, so there is nothing to record."
        default: return nil
        }
    }

    /// Starts listening. The person takes the browser first, so only their own actions are written down.
    @discardableResult
    public func startDemo(botId: String) -> String? {
        if let refusal = demoRecordingRefusal(botId: botId) { return refusal }
        takeControl(botId: botId)
        demoRecorder = DemoRecorder()
        demoRecordingBotId = botId
        recordAudit(type: .computerControlTaken, botId: botId, tool: "demo.record", reason: "Person started teaching by demonstration.", allowed: true, forwarded: true)
        return nil
    }

    /// Called with each thing the page reports. Ignored unless a recording is running for this bot and the person holds the browser.
    public func recordDemoEvent(botId: String, _ event: DemoEvent) {
        guard demoRecordingBotId == botId, computers[botId]?.controlHolder == .user else { return }
        demoRecorder.add(event)
        demoStepCount = demoRecorder.steps.count
    }

    public func cancelDemo() {
        demoRecordingBotId = nil
        demoRecorder = DemoRecorder()
        demoStepCount = 0
    }

    /// Ends the recording and saves the steps as a skill proposal the person reviews in Skills. Returns a message for the person.
    @discardableResult
    public func finishDemo(title: String) -> String {
        guard let botId = demoRecordingBotId else { return "Nothing was being recorded." }
        let recorded = demoRecorder
        cancelDemo()
        guard !recorded.isEmpty else { return "Nothing was recorded, so no skill was made." }
        let playbook = DemoPlaybook.render(title: title, steps: recorded.steps)
        let result = proposeSkill(botId: botId, id: playbook.id, description: playbook.description, body: playbook.body, keywords: "demonstration, recorded, browser")
        return "\(recorded.steps.count) steps: \(result.output)"
    }
}
