import Foundation

extension AppStore {
    /// One time: tools that used to come on silently with another (Shell → Shortcuts, Remember →
    /// Search memory and Forget, …) are written into each bot's toggles, so every switch is real and
    /// can be turned off. Bots keep exactly what they could do before.
    public func grantImpliedTools() {
        guard !appConfig.impliedToolsGranted else { return }
        for idx in bots.indices {
            let extra = AgentToolCatalog.impliedGrants(from: bots[idx].enabledTools)
            bots[idx].enabledTools.append(contentsOf: extra)
        }
        appConfig.defaultEnabledTools.append(
            contentsOf: AgentToolCatalog.impliedGrants(from: appConfig.defaultEnabledTools)
        )
        appConfig.impliedToolsGranted = true
        save()
    }
}
