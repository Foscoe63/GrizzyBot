import AppKit
import GrizzyBotCore
import SwiftUI

struct MenuBarView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("GrizzyBot")
                .font(.headline)
            Text(statusLine)
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            if store.missedRoutineCount > 0 {
                Text("\(store.missedRoutineCount) missed routine\(store.missedRoutineCount == 1 ? "" : "s")")
                    .foregroundStyle(.orange)
            }
            ForEach(store.allRoutines.prefix(5)) { routine in
                Button(routine.name) {
                    store.runRoutine(routine.id)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            Divider()
            Button("Open GrizzyBot") {
                MainWindowController.showMainWindow()
            }
            Button("Open Routines") {
                MainWindowController.showMainWindow()
                store.showRoutinesPage()
            }
            Button("Quit") {
                NSApp.terminate(nil)
            }
        }
        .padding(8)
        .frame(minWidth: 220)
    }

    private var statusLine: String {
        let working = store.bots.filter { $0.status == "working" }.count
        if working > 0 { return "\(working) bot\(working == 1 ? "" : "s") working" }
        if let next = store.allRoutines.first(where: { $0.active })?.nextRunAt {
            return "Next routine \(next.formatted(date: .omitted, time: .shortened))"
        }
        return "Idle"
    }
}
