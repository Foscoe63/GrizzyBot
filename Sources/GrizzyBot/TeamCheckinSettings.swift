import GrizzyBotCore
import SwiftUI

/// Chief of Staff setting: check in at fixed times of day. See `TeamCheckin`.
struct TeamCheckinSettings: View {
    @Environment(AppStore.self) private var store
    let botId: String

    @State private var draft = ""
    @State private var loadedFor: String?

    private var times: [String] { store.teamCheckinTimes(botId: botId) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Daily check-ins")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.textBright)
            Text("At these times (24-hour, this Mac's zone, comma separated) this bot looks over approvals, recent routines and the team, and messages you only if something is worth saying. Skipped while you're chatting. Leave empty to turn off.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
            HStack {
                TextField("e.g. 09:00, 16:30", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12.5, design: .monospaced))
                    .onSubmit(save)
                GrizzyButton(title: "Save", variant: .cream, size: .sm, action: save)
            }
            Toggle("Keep an eye on my day", isOn: Binding(
                get: { store.isDayWatchOn(botId: botId) },
                set: { store.setDayWatch(botId: botId, enabled: $0) }
            ))
            .font(.system(size: 12.5))
            Text("Weekdays 9–17, every two hours: calendar, mail, approvals and failing routines. Silent unless something needs you.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textMuted)
        }
        .padding(.top, 8)
        .onAppear(perform: load)
        .onChange(of: botId) { _, _ in load() }
    }

    private func load() {
        draft = times.joined(separator: ", ")
        loadedFor = botId
    }

    private func save() {
        let parsed = draft.split(whereSeparator: { ",; ".contains($0) }).map(String.init)
        store.setTeamCheckins(botId: botId, times: parsed)
        draft = times.joined(separator: ", ")
    }
}
