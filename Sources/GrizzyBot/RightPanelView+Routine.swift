import AppKit
import GrizzyBotCore
import SwiftUI
import UniformTypeIdentifiers

extension RightPanelView {
    // MARK: - Routine

    var routinePanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button {
                    store.openPanel(.computer)
                } label: {
                    Text("‹")
                        .font(.system(size: 20))
                        .foregroundStyle(Theme.textChevron)
                }
                .buttonStyle(.plain)
                Spacer()
                Text("Routine")
                    .font(.system(size: 15.5, weight: .medium))
                    .foregroundStyle(Theme.textBrightAlt)
                Spacer()
                Button {
                    store.openPanel(nil)
                } label: {
                    Text("✕")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textMuted)
                }
                .buttonStyle(.plain)
            }

            GrizzyField(
                label: "Name",
                labelSize: 14,
                placeholder: "Name",
                text: Binding(
                    get: { store.routineDraft.name },
                    set: { store.routineDraft.name = $0 }
                )
            )
            .padding(.top, 20)

            GrizzyField(
                label: "Instruction",
                labelSize: 14,
                placeholder: "What this routine should do on every run",
                text: Binding(
                    get: { store.routineDraft.prompt },
                    set: { store.routineDraft.prompt = $0 }
                ),
                axis: .vertical,
                lineLimit: 6...18
            )
            .padding(.top, 12)

            Text("Assign to bot")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 16)
                .padding(.bottom, 8)

            if store.visibleBots.isEmpty {
                Text("Create a bot first.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textMuted)
            } else {
                let options = store.visibleBots
                let selected = options.first(where: { $0.id == store.routineDraft.botId }) ?? options.first!
                GrizzySelect(
                    options: options.map(\.id),
                    selection: Binding(
                        get: {
                            store.routineDraft.botId.isEmpty
                                ? (selected.id)
                                : store.routineDraft.botId
                        },
                        set: { store.routineDraft.botId = $0 }
                    ),
                    label: { id in
                        store.bots.first(where: { $0.id == id })?.name ?? id
                    }
                )
            }

            Text("When to run")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 16)
                .padding(.bottom, 8)

            RoutineScheduleView(
                preset: Binding(
                    get: { store.routineDraft.preset },
                    set: { store.routineDraft.preset = $0 }
                )
            )

            Button {
                store.saveRoutineDraft(botId: bot?.id)
            } label: {
                Text(store.editingRoutineId == nil ? "Create routine" : "Save changes")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textCream)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Theme.bgCream)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.top, 20)
            .disabled(store.visibleBots.isEmpty)
            .opacity(store.visibleBots.isEmpty ? 0.45 : 1)

            if let editingId = store.editingRoutineId {
                RoutineTriggerOptions(routineId: editingId)
                HStack(spacing: 12) {
                    Button {
                        store.runRoutine(editingId)
                    } label: {
                        Text("Run now")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.textBright)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .overlay {
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .stroke(Theme.borderInputsDark, lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)

                    Button {
                        store.deleteRoutine(editingId)
                    } label: {
                        Text("Delete")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.orange)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 14)
            }
        }
    }
}
