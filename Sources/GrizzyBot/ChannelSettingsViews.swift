import AppKit
import GrizzyBotCore
import SwiftUI

/// Settings body for the Telegram link. Pairing is two-sided on purpose: a stranger who finds the
/// bot gets a code, and only someone at this Mac can turn that code into access.
struct TelegramSettingsBody: View {
    @Environment(AppStore.self) private var store

    @State private var token = ""
    @State private var code = ""
    @State private var working = false
    @State private var message: String?

    private var settings: TelegramSettings { store.appConfig.telegram }
    private var connected: Bool { store.telegramToken != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if connected {
                connectedBody
            } else {
                setupBody
            }
            if let message {
                Text(message)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)
            }
            if let notice = store.telegramNotice, connected {
                Text(notice)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.orange)
            }
        }
    }

    private var setupBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("1. In Telegram, message @BotFather and send /newbot. 2. Paste the token it gives you here. 3. Message your new bot from your phone and enter the code it replies with.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
            GrizzyField(placeholder: "Bot token from BotFather", text: $token, secure: true)
            GrizzyButton(title: working ? "Checking…" : "Connect", variant: .cream, size: .sm, disabled: working) {
                working = true
                Task {
                    message = await store.connectTelegram(token: token)
                    if message == nil { token = "" }
                    working = false
                }
            }
        }
    }

    @ViewBuilder
    private var connectedBody: some View {
        HStack {
            Text(settings.botUsername.map { "Connected as @\($0)" } ?? "Connected")
                .font(.system(size: 13))
                .foregroundStyle(Theme.green)
            Spacer()
            Toggle("On", isOn: Binding(
                get: { settings.enabled },
                set: { store.setTelegramEnabled($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
        }

        let requests = store.telegramPairingRequests
        VStack(alignment: .leading, spacing: 8) {
            Text("Connect a chat")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            if requests.isEmpty {
                Text("Message your bot from Telegram. It replies with a 6-digit code — enter it here.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textMuted)
            } else {
                ForEach(requests, id: \.code) { request in
                    Text("\(request.name) is waiting")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textBright)
                }
            }
            HStack(spacing: 8) {
                GrizzyField(placeholder: "123456", text: $code)
                GrizzyButton(title: "Approve", variant: .cream, size: .sm, disabled: code.trimmingCharacters(in: .whitespaces).isEmpty) {
                    if let name = store.approveTelegramPairing(code: code) {
                        message = "Connected \(name)."
                        code = ""
                    } else {
                        message = "That code isn't right, or it expired."
                    }
                }
            }
        }

        if !settings.allowedChatIds.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Connected chats")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                ForEach(settings.allowedChatIds, id: \.self) { chatId in
                    HStack {
                        let botName = settings.chatBots[String(chatId)]
                            .flatMap { id in store.bots.first(where: { $0.id == id })?.name }
                        Text("Chat \(String(chatId))" + (botName.map { " → \($0)" } ?? ""))
                            .font(.system(size: 12.5, design: .monospaced))
                            .foregroundStyle(Theme.textBright)
                        Spacer()
                        Button("Remove") { store.revokeTelegramChat(chatId) }
                            .buttonStyle(.plain)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.orange)
                    }
                }
            }
        }

        Picker("Default bot", selection: Binding(
            get: { settings.defaultBotId ?? "" },
            set: { store.setTelegramDefaultBot($0.isEmpty ? nil : $0) }
        )) {
            Text("Chief of staff / first bot").tag("")
            ForEach(store.visibleBots) { bot in
                Text(bot.name).tag(bot.id)
            }
        }
        .pickerStyle(.menu)

        Toggle("Send me a note when a routine finishes", isOn: Binding(
            get: { settings.notifyRoutines },
            set: { store.setTelegramNotifyRoutines($0) }
        ))
        .toggleStyle(.switch)
        .font(.system(size: 13))

        Button("Disconnect Telegram") { store.disconnectTelegram() }
            .buttonStyle(.plain)
            .font(.system(size: 12.5))
            .foregroundStyle(Theme.orange)
    }
}

/// Settings body for the loopback webhook listener.
struct WebhookSettingsBody: View {
    @Environment(AppStore.self) private var store
    @State private var portText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Accept webhooks on this Mac", isOn: Binding(
                get: { store.appConfig.webhooksEnabled },
                set: { on in
                    var config = store.appConfig
                    config.webhooksEnabled = on
                    store.saveAppConfig(config)
                }
            ))
            .toggleStyle(.switch)
            .font(.system(size: 13))

            HStack(spacing: 8) {
                Text("Port")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                GrizzyField(placeholder: String(store.appConfig.webhookPort), text: $portText)
                    .frame(width: 100)
                GrizzyButton(title: "Set", variant: .cream, size: .sm) {
                    if let port = Int(portText), (1024...65_535).contains(port) {
                        var config = store.appConfig
                        config.webhookPort = port
                        store.saveAppConfig(config)
                        portText = ""
                    }
                }
            }
            Text("Listens on 127.0.0.1 only. Each routine has its own secret (turn on its Webhook option in the routine editor). To reach it from outside, tunnel just this port — for example with Tailscale Funnel.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
        }
    }
}

/// Share a whole team as one Markdown file, or bring one in.
struct TeamsSettingsBody: View {
    @Environment(AppStore.self) private var store
    @State private var teamName = ""
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GrizzyField(label: "Team name", placeholder: "My team", text: $teamName)
            HStack(spacing: 10) {
                GrizzyButton(title: "Export team…", variant: .cream, size: .sm) { export() }
                GrizzyButton(title: "Import team…", variant: .cream, size: .sm) { importTeam() }
                GrizzyButton(title: "Import agent folder…", variant: .cream, size: .sm) { importAgentFolder() }
            }
            if let notice {
                Text(notice)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)
            }
            Text("The file lists your bots, rooms, and routines. It never includes keys, chats, memory, or computer access, and anything that looks like a secret is removed. Imported routines start paused and imported bots ask before they act.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textMuted)
        }
    }

    private func export() {
        let name = teamName.trimmingCharacters(in: .whitespaces).isEmpty ? "My team" : teamName
        let markdown = store.exportTeamPackage(name: name).markdown()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name.replacingOccurrences(of: "/", with: "-") + ".team.md"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try markdown.write(to: url, atomically: true, encoding: .utf8)
            notice = "Saved \(url.lastPathComponent)."
        } catch {
            notice = "Couldn't save: \(error.localizedDescription)"
        }
    }

    /// An OpenClaw/Hermes-style workspace: SOUL.md, AGENTS.md, MEMORY.md, HEARTBEAT.md, skills/.
    private func importAgentFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.showsHiddenFiles = true
        panel.message = "Choose an agent workspace folder (for example ~/.openclaw/workspace)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let plan = WorkspaceImport.plan(folder: url)
        guard !plan.isEmpty else {
            notice = plan.preview()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Import this agent?"
        alert.informativeText = plan.preview()
        alert.addButton(withTitle: "Import")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let result = store.importWorkspace(plan) else { return }
        let flagged = result.skillReports.filter { $0.risk > .clean }
        notice = "Created “\(result.bot.name)”."
            + (flagged.isEmpty ? "" : " \(flagged.count) imported skill\(flagged.count == 1 ? " was" : "s were") flagged — review in Skills before enabling.")
    }

    private func importTeam() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let package = try TeamPackage.parse(markdown: text)
            let alert = NSAlert()
            alert.messageText = "Import “\(package.name)”?"
            alert.informativeText = package.preview()
            alert.addButton(withTitle: "Import")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let created = store.importTeamPackage(package)
            notice = "Added \(created.count) bot\(created.count == 1 ? "" : "s")."
        } catch {
            notice = error.localizedDescription
        }
    }
}
