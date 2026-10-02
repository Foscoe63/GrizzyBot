import AppKit
import GrizzyBotCore
import SwiftUI
import UniformTypeIdentifiers

extension RightPanelView {
    // MARK: - Computer

    var computerPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader(
                left: computer?.state.rawValue ?? bot?.status ?? "",
                showGear: true
            )

            ZStack {
                Theme.bgScreen
                if store.computerOpen {
                    screenLabel
                        .font(.system(size: 13.5))
                        .foregroundStyle(Theme.textMuted)
                        .multilineTextAlignment(.center)
                        .padding(16)
                } else if let bot, store.isThisMacComputer(botId: bot.id) || computer?.kind == .desktop {
                    if isResizing {
                        Theme.bgScreen
                        Text("Resizing…")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.textMuted)
                    } else {
                        ThisMacScreenPreview(botId: bot.id, pollSeconds: 3, fill: true)
                    }
                } else if let bot, let data = AppComputerRuntime.shared.cachedJPEG(for: bot.id),
                          let image = NSImage(data: data) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                        .clipped()
                } else {
                    screenLabel
                        .font(.system(size: 13.5))
                        .foregroundStyle(Theme.textMuted)
                        .multilineTextAlignment(.center)
                        .padding(16)
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(16 / 10, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .onTapGesture { store.openComputerOverlay() }

            VStack(alignment: .leading, spacing: 10) {
                Text(statusCaption)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let bot {
                    if computer?.controlHolder == .user {
                        GrizzyButton(title: "Release", variant: .outline, size: .sm) {
                            store.release(botId: bot.id)
                        }
                    } else {
                        // Take control only — full window is the preview tap. Avoids overlay remount churn.
                        GrizzyButton(title: "Take control", variant: .outline, size: .sm) {
                            store.takeControl(botId: bot.id)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 12)

            if let bot, store.isThisMacComputer(botId: bot.id) || computer?.kind == .desktop {
                Text("Preview only — the bot clicks your real Mac. Take control to type passwords yourself.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }

            Text("Routines")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 30)
                .padding(.bottom, 12)

            if let bot {
                let list = store.routines(for: bot.id)
                ForEach(list) { routine in
                    HStack(spacing: 6) {
                        Button {
                            store.openRoutine(routine)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "clock")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(Theme.orange)
                                Text(routine.name)
                                    .font(.system(size: 14.5))
                                    .foregroundStyle(Theme.textBright)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(Cron.formatCron(routine.cron))
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.textMuted)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Button {
                            store.runRoutine(routine.id)
                        } label: {
                            Text("▶")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textCream)
                                .frame(width: 28, height: 28)
                                .background(Theme.bgCream.opacity(0.9))
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help("Run now")
                    }
                    .contextMenu {
                        Button("Edit") { store.openRoutine(routine) }
                        Button("Run now") { store.runRoutine(routine.id) }
                        Button(routine.active ? "Pause" : "Resume") {
                            store.setRoutineActive(routine.id, active: !routine.active)
                        }
                        Button("Delete", role: .destructive) {
                            store.deleteRoutine(routine.id)
                        }
                    }
                }

                Button {
                    store.runNow(botId: bot.id)
                } label: {
                    Text("Run now")
                        .font(.system(size: 14.5))
                        .foregroundStyle(Theme.textSidebarIcon)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .help("Run the next due routine")

                Button {
                    store.openNewRoutine()
                } label: {
                    Text("+ New routine")
                        .font(.system(size: 14.5))
                        .foregroundStyle(Theme.textSidebarIcon)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)

                Text("Files")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 24)
                    .padding(.bottom, 10)

                let entries = store.botHomeEntries(botId: bot.id)
                if entries.isEmpty {
                    Text("Ask the bot to write a note, list files, or search the web.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textMuted)
                        .padding(.horizontal, 8)
                } else {
                    ForEach(entries) { entry in
                        HStack(spacing: 8) {
                            Text(entry.isDirectory ? "📁" : "📄")
                                .font(.system(size: 12))
                            Text(entry.path)
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.textBright)
                                .lineLimit(1)
                            Spacer()
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                    }
                }
            }
        }
    }

    @ViewBuilder
    var screenLabel: some View {
        if store.computerOpen {
            Text("Open in full window")
        } else if let bot, store.isThisMacComputer(botId: bot.id) || computer?.kind == .desktop {
            Text("This Mac preview — Screen Recording required")
        } else if store.booting || computer?.state == .booting {
            Text("Booting live desktop…")
        } else if computer?.state == .running {
            Text("\(bot?.name ?? "Bot")'s screen")
        } else if computer?.state == .suspended {
            Text("Computer is asleep — take control to wake it")
        } else if computer?.state == .error {
            Text("Computer failed to boot")
        } else {
            Text("Computer is stopped")
        }
    }

    var statusCaption: String {
        if computer?.controlHolder == .user { return "You have control (real Mac)" }
        if let bot, store.isThisMacComputer(botId: bot.id) || computer?.kind == .desktop {
            return "This Mac · live preview"
        }
        if computer?.state == .suspended { return "Asleep" }
        return "\(bot?.name ?? "Bot")'s screen"
    }

    // MARK: - Create
}
