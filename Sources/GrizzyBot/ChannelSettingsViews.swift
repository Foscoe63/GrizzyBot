import AppKit
import GrizzyBotCore
import SwiftUI
import UniformTypeIdentifiers

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

        SettingsToggle(title: "Send me a note when a routine finishes", isOn: Binding(
            get: { settings.notifyRoutines },
            set: { store.setTelegramNotifyRoutines($0) }
        ))

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
    @State private var portNote: String?

    private func applyPort() {
        guard let port = Int(portText.trimmingCharacters(in: .whitespaces)), (1024...65_535).contains(port) else {
            portNote = "Port must be a number between 1024 and 65535."
            return
        }
        var config = store.appConfig
        config.webhookPort = port
        store.saveAppConfig(config)
        portText = ""
        portNote = "Listening on port \(port)."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsToggle(title: "Accept webhooks on this Mac", isOn: Binding(
                get: { store.appConfig.webhooksEnabled },
                set: { on in
                    var config = store.appConfig
                    config.webhooksEnabled = on
                    store.saveAppConfig(config)
                }
            ))

            HStack(spacing: 8) {
                Text("Port")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                GrizzyField(placeholder: String(store.appConfig.webhookPort), text: $portText, onCommit: { applyPort() })
                    .frame(width: 100)
                GrizzyButton(title: "Set", variant: .cream, size: .sm) { applyPort() }
            }
            if let portNote {
                Text(portNote)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)
            }
            Text("Listens on 127.0.0.1 only. Each routine has its own secret (turn on its Webhook option in the routine editor). To reach it from outside, tunnel just this port — for example with Tailscale Funnel.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
        }
    }
}

/// Let Claude Desktop, Cursor, or Claude Code drive the bots through MCP.
struct ControlPlaneSettingsBody: View {
    @Environment(AppStore.self) private var store
    @State private var shownToken: String?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsToggle(title: "Let MCP clients use my bots", isOn: Binding(
                get: { store.appConfig.controlPlaneEnabled },
                set: { on in
                    var config = store.appConfig
                    config.controlPlaneEnabled = on
                    store.saveAppConfig(config)
                    if on { shownToken = store.controlPlaneToken() ?? store.rotateControlPlaneToken() }
                }
            ))

            if store.appConfig.controlPlaneEnabled {
                Text("http://127.0.0.1:\(store.appConfig.controlPlanePort)/mcp")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.textBright)
                    .textSelection(.enabled)
                HStack(spacing: 10) {
                    GrizzyButton(title: copied ? "Copied" : "Copy Claude Code command", variant: .cream, size: .sm) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(store.controlPlaneClaudeCommand(), forType: .string)
                        copied = true
                    }
                    GrizzyButton(title: "New token", variant: .cream, size: .sm) {
                        shownToken = store.rotateControlPlaneToken()
                        copied = false
                    }
                }
                if let shownToken {
                    Text("Token: \(shownToken)")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Theme.textBright)
                        .textSelection(.enabled)
                }
            }
            Text("Loopback only, bearer token required. A client can list bots, read and search chats, message a bot and wait for the answer, stop a run, and switch a bot's model. It cannot answer approvals, delete anything, see keys, change settings, or touch the computer.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
        }
    }
}

/// Send a trace of every run and tool call to an OpenTelemetry collector.
struct TracingSettingsBody: View {
    @Environment(AppStore.self) private var store
    @State private var endpoint = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GrizzyField(label: "OTLP/HTTP endpoint", placeholder: "http://localhost:4318 (empty = off)", text: $endpoint, onCommit: { saveEndpoint() })
            GrizzyButton(title: "Save", variant: .cream, size: .sm) { saveEndpoint() }
            Text("One span per run and one per tool call: tool name, duration, success, model, token counts. No prompts, no tool arguments, no file contents. Works with Jaeger, Grafana Tempo, Langfuse, Honeycomb, and any OpenTelemetry collector.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
        }
        .onAppear { endpoint = store.appConfig.otlpEndpoint }
    }

    private func saveEndpoint() {
        var config = store.appConfig
        config.otlpEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        store.saveAppConfig(config)
    }
}

/// Share a whole team as one Markdown file, or bring one in.
struct TeamsSettingsBody: View {
    @Environment(AppStore.self) private var store
    @State private var teamName = ""
    @State private var notice: String?
    @State private var showExport = false
    @State private var showLibrary = false
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GrizzyField(label: "Team name", placeholder: "My team", text: $teamName)
            HStack(spacing: 10) {
                GrizzyButton(title: "Browse teams…", variant: .cream, size: .sm) { showLibrary = true }
                GrizzyButton(title: "Export team…", variant: .cream, size: .sm) { showExport = true }
                GrizzyButton(title: "Import team…", variant: .cream, size: .sm) { importTeam() }
                GrizzyButton(title: "Import from link…", variant: .cream, size: .sm) { importTeamFromLink() }
                GrizzyButton(title: "Import agent folder…", variant: .cream, size: .sm) { importAgentFolder() }
                GrizzyButton(title: "Import recipe…", variant: .cream, size: .sm) { importRecipe() }
            }
            if let notice {
                Text(notice)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)
            }
            Text("The file lists your bots, rooms, routines, the departments you choose, and the accounts worth connecting. It never includes keys, chats, memory, or computer access, and anything that looks like a secret is removed. Imported routines start paused and imported bots ask before they act. You can also drop a team file here, or open one from Finder.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textMuted)
        }
        .padding(8)
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Theme.orange.opacity(dropTargeted ? 0.9 : 0), style: StrokeStyle(lineWidth: 1.5, dash: [5])))
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in handleDrop(providers) }
        .sheet(isPresented: $showExport) { TeamExportSheet(name: teamName) }
        .sheet(isPresented: $showLibrary) { TeamLibrarySheet() }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in TeamFileOpener.open(url, store: store) }
        }
        return true
    }

    /// An OpenClaw/Hermes-style workspace: SOUL.md, AGENTS.md, MEMORY.md, HEARTBEAT.md, skills/.
    private func importRecipe() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.message = "Choose a recipe (.md). Run it with /recipe name."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let recipe = try RecipeLibrary.importFile(url, root: store.userRootForTesting)
            notice = "Imported recipe “\(recipe.id)”. Run it with /recipe \(recipe.id)."
        } catch {
            notice = error.localizedDescription
        }
    }

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
            store.proposeTeam(try TeamPackage.parse(markdown: text))
        } catch {
            notice = error.localizedDescription
        }
    }

    private func importTeamFromLink() {
        let alert = NSAlert()
        alert.messageText = "Import a team from a link"
        alert.informativeText = "Paste an https link to a team file. You'll see what it adds before anything is created."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "https://example.com/newsroom.team.md"
        alert.accessoryView = field
        alert.addButton(withTitle: "Fetch")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn,
              let url = URL(string: field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return }
        notice = "Fetching…"
        Task { @MainActor in
            do {
                store.proposeTeam(try await TeamPackage.fetch(url: url))
                notice = nil
            } catch {
                notice = error.localizedDescription
            }
        }
    }
}

/// A phone-friendly web companion served from this Mac.
struct CompanionSettingsBody: View {
    @Environment(AppStore.self) private var store
    @State private var shownToken: String?
    @State private var copied = false

    private var pairingURL: String? {
        guard let token = shownToken ?? store.companionToken(),
              let address = store.companionAddresses().last(where: { !$0.contains("localhost") }) ?? store.companionAddresses().first
        else { return nil }
        return "\(address)/#token=\(token)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsToggle(title: "Phone companion", isOn: Binding(
                get: { store.appConfig.companionEnabled },
                set: { on in
                    var config = store.appConfig
                    config.companionEnabled = on
                    store.saveAppConfig(config)
                    if on { shownToken = store.companionToken() ?? store.rotateCompanionToken() }
                }
            ))

            SettingsToggle(title: "Reachable from other devices (Tailscale or this network)", isOn: Binding(
                get: { store.appConfig.companionAllowNetwork },
                set: { on in
                    var config = store.appConfig
                    config.companionAllowNetwork = on
                    store.saveAppConfig(config)
                    Task { await store.restartCompanion() }
                }
            ))
            .disabled(!store.appConfig.companionEnabled)

            if store.appConfig.companionEnabled {
                if store.appConfig.companionAllowNetwork {
                    Text("This page is plain HTTP. Use it over Tailscale (encrypted) or on a network you trust, and don't expose the port to the internet.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.orange)
                }
                if let url = pairingURL, let image = QRCode.image(for: url) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 150, height: 150)
                        .background(Color.white)
                    Text("Scan with your iPhone camera, open the link, then Share → Add to Home Screen.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textSecondary)
                }
                ForEach(store.companionAddresses(), id: \.self) { address in
                    Text(address)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.textBright)
                        .textSelection(.enabled)
                }
                HStack(spacing: 10) {
                    GrizzyButton(title: copied ? "Copied" : "Copy pairing link", variant: .cream, size: .sm) {
                        if let url = pairingURL {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url, forType: .string)
                            copied = true
                        }
                    }
                    GrizzyButton(title: "New token", variant: .cream, size: .sm) {
                        shownToken = store.rotateCompanionToken()
                        copied = false
                    }
                }
            }
            Text("See your bots, read and send messages, stop a run, and Allow or Deny an approval from your phone. Secrets, \"always allow\", and settings stay on the Mac. A new token signs out every phone.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
        }
    }
}

enum QRCode {
    static func image(for text: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
