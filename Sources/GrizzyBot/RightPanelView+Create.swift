import AppKit
import GrizzyBotCore
import SwiftUI
import UniformTypeIdentifiers

extension RightPanelView {
    var createPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("New bot")
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                closeButton
            }

            GrizzyField(label: "Name", placeholder: "Name this bot", text: $createName)
                .padding(.top, 24)

            Text("Start from")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 16)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(BotTemplates.all) { template in
                    Button {
                        createName = template.name
                        createTitle = template.title
                        createDescription = template.blurb
                        _ = store.createBot(from: template, name: template.name)
                        createName = ""
                        createTitle = ""
                        createDescription = ""
                        store.openPanel(nil)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(template.name)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Theme.textBright)
                            Text(template.blurb)
                                .font(.system(size: 12.5))
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Theme.bgCard)
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }

            GrizzyField(label: "Title", placeholder: "Describe what this bot does", text: $createTitle)
                .padding(.top, 12)
            GrizzyField(
                label: "Description",
                placeholder: "What this bot is for",
                text: $createDescription,
                axis: .vertical,
                lineLimit: 4...8
            )
            .padding(.top, 12)

            Button {
                let name = createName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                _ = store.createBot(
                    name: name,
                    title: createTitle,
                    description: createDescription,
                    instructions: createDescription
                )
                createName = ""
                createTitle = ""
                createDescription = ""
                store.openPanel(nil)
            } label: {
                Text("Create")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textCream)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Theme.bgCream)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .opacity(createName.trimmingCharacters(in: .whitespaces).isEmpty ? 0.45 : 1)
            }
            .buttonStyle(.plain)
            .disabled(createName.trimmingCharacters(in: .whitespaces).isEmpty)
            .padding(.top, 16)
        }
    }

    // MARK: - Settings

    func avatarControls(_ bot: Bot) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                ForEach(BotAvatarShape.allCases) { shape in
                    let selected = BotAvatarShape.resolve(bot.avatarShape) == shape
                    Button {
                        store.setAvatarShape(botId: bot.id, shape: shape)
                    } label: {
                        AvatarBodyShape(shape)
                            .fill(Color(hex: bot.color))
                            .frame(width: 22, height: 22)
                            .padding(5)
                            .background(selected ? Theme.bgHoverRow : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help(shape.label)
                }
            }
            HStack(spacing: 14) {
                Button("Upload picture…") { pickAvatarImage(for: bot) }
                if bot.avatarImageRev != nil {
                    Button("Remove") { store.clearAvatarImage(botId: bot.id) }
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(Theme.textMuted)
        }
        .frame(maxWidth: .infinity)
    }

    func pickAvatarImage(for bot: Bot) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a picture for \(bot.name)"
        guard panel.runModal() == .OK, let url = panel.url,
              let png = AvatarImageCache.normalizedPNG(from: url)
        else { return }
        store.setAvatarImage(botId: bot.id, png: png)
    }
}
