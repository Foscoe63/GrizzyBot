import AppKit
import GrizzyBotCore
import SwiftUI
import UniformTypeIdentifiers

extension AppSettingsOverlayView {
    @ViewBuilder
    var connectionsSection: some View {
        settingsCard(
            title: "Keys",
            subtitle: "Composio Connect turns Plugins into real browser OAuth (Slack, GitHub, Box, …). Google apps can use Composio or your own Client ID/Secret below. Keys stay on this Mac. Clear removes a stored key."
        ) {
            secretRow(
                title: "Composio Connect",
                configured: !(store.appConfig.composioConnectKey ?? "").isEmpty,
                text: $composioConnect,
                onClear: { store.clearSecret(.composioConnect) }
            )
            secretRow(
                title: "Composio API",
                configured: store.appConfig.composioApiKey != nil,
                text: $composioApi,
                onClear: { store.clearSecret(.composioApi) }
            )
                .padding(.top, 12)
            secretRow(
                title: "Box.com",
                configured: store.appConfig.boxConfigured,
                text: $boxToken,
                onClear: { store.clearSecret(.box) }
            )
                .padding(.top, 12)
            secretRow(
                title: "Brave Search (optional)",
                configured: store.appConfig.braveSearchConfigured,
                text: $braveSearchKey,
                onClear: { store.clearSecret(.braveSearch) }
            )
                .padding(.top, 12)
            Text("Box.com is an optional developer token for the Box plugin when you are not using Composio Connect. Brave Search is used for web_search when set; otherwise DuckDuckGo and Wikipedia.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 8)
            GrizzyButton(title: "Save keys", variant: .cream, size: .sm) {
                persistKeys()
            }
            .padding(.top, 14)
        }

        settingsCard(
            title: "Telegram",
            subtitle: "Talk to your bots from your phone. This Mac asks Telegram for new messages, so nothing has to be reachable from the internet, and only chats you approve here are ever answered."
        ) {
            TelegramSettingsBody()
        }

        settingsCard(
            title: "Webhooks",
            subtitle: "Let another program or service start a routine."
        ) {
            WebhookSettingsBody()
        }

        settingsCard(
            title: "Google (bypass Composio)",
            subtitle: "Your Google Cloud OAuth Client ID/Secret for Gmail, Calendar, Sheets, Docs, and Drive. Keep using the same credentials if sign-in already worked once."
        ) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Authorized redirect URI")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                    Text(GoogleOAuth.loopbackRedirectURI)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Theme.textBright)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 8)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        GoogleOAuth.loopbackRedirectURI,
                        forType: .string
                    )
                }
                .buttonStyle(.plain)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.textGhost)
            }
            .padding(.bottom, 4)

            Text("Paste that exact URI (no trailing slash) into Google Cloud → your OAuth client → Authorized redirect URIs, then Save.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            DisclosureGroup(isExpanded: $googleSetupExpanded) {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(GoogleOAuth.setupGuide.enumerated()), id: \.element.id) { index, step in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(index + 1). \(step.title)")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.textBright)
                            Text(step.body)
                                .font(.system(size: 12.5))
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if let link = step.linkURL {
                                Button(step.linkTitle ?? link.host ?? "Open") {
                                    NSWorkspace.shared.open(link)
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 12.5))
                                .foregroundStyle(Theme.textGhost)
                                .padding(.top, 2)
                            }
                        }
                    }
                }
                .padding(.top, 8)
            } label: {
                Text(googleSetupExpanded ? "Hide setup guide" : "Show step-by-step setup guide")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textBright)
            }

            secretRow(
                title: "Google Client ID",
                configured: !(store.appConfig.googleClientId ?? "").isEmpty,
                text: $googleClientId,
                onClear: { store.clearSecret(.googleClientId) }
            )
            .padding(.top, 12)
            secretRow(
                title: "Google Client Secret",
                configured: !(store.appConfig.googleClientSecret ?? "").isEmpty,
                text: $googleClientSecret,
                onClear: { store.clearSecret(.googleClientSecret) }
            )
            .padding(.top, 12)

            Text(
                store.appConfig.googleOAuthConfigured
                    ? "Configured. Open Plugins and Connect Gmail, or use Sign in with Google for all Google apps at once."
                    : "After saving both fields, open Plugins → Connect on Gmail (or Sign in with Google)."
            )
            .font(.system(size: 12.5))
            .foregroundStyle(Theme.textSecondary)
            .padding(.top, 8)

            HStack(spacing: 10) {
                GrizzyButton(title: "Save Google credentials", variant: .cream, size: .sm) {
                    persistGoogleKeys()
                }
                if store.appConfig.googleOAuthConfigured {
                    GrizzyButton(title: "Open Plugins", variant: .outline, size: .sm) {
                        store.closeAppSettings()
                        store.openPlugins()
                    }
                }
            }
            .padding(.top, 14)
        }

        settingsCard(
            title: "Subscription sign-in",
            subtitle: "ChatGPT Plus/Pro, Copilot, and SuperGrok. Opens the model Connect sheet — no API key required."
        ) {
            GrizzyButton(title: "Open model sign-in", variant: .cream, size: .sm) {
                store.closeAppSettings()
                store.openModelSettings()
            }
        }
    }

    var mcpEditorForm: some View {
        VStack(alignment: .leading, spacing: 0) {
            GrizzyField(label: "Name", placeholder: "filesystem", text: $mcpName)
            VStack(alignment: .leading, spacing: 6) {
                Text("Transport")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                GrizzySelect(options: McpTransport.allCases, selection: $mcpTransport)
            }
            .padding(.top, 8)

            if mcpTransport == .stdio {
                GrizzyField(
                    label: "Command",
                    placeholder: "npx",
                    text: $mcpCommand
                )
                .padding(.top, 8)
                GrizzyField(
                    label: "Args (space-separated)",
                    placeholder: "-y @modelcontextprotocol/server-filesystem /tmp",
                    text: $mcpArgs
                )
                .padding(.top, 8)
                GrizzyField(
                    label: "Env (KEY=value per line)",
                    placeholder: "API_KEY=…",
                    text: $mcpEnv,
                    axis: .vertical,
                    lineLimit: 2...4
                )
                .padding(.top, 8)
            } else {
                GrizzyField(
                    label: "URL",
                    placeholder: mcpTransport == .sse
                        ? "https://example.com/sse"
                        : "https://example.com/mcp",
                    text: $mcpUrl
                )
                .padding(.top, 8)
                GrizzyField(
                    label: "Headers (Name: value per line)",
                    placeholder: "Authorization: Bearer …",
                    text: $mcpHeaders,
                    axis: .vertical,
                    lineLimit: 2...4
                )
                .padding(.top, 8)
            }

            HStack(spacing: 10) {
                GrizzyButton(
                    title: editingMcpId == nil ? "Add MCP server" : "Save changes",
                    variant: .cream,
                    size: .sm,
                    disabled: !canAddMcp
                ) {
                    saveMcpServer()
                }

                if editingMcpId != nil {
                    Button("Cancel") {
                        clearMcpForm()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(.top, 12)
        }
    }

    var canAddMcp: Bool {
        let nameOk = !mcpName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch mcpTransport {
        case .stdio:
            return nameOk && !mcpCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .http, .sse:
            return nameOk && !mcpUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    func beginEdit(_ server: McpServer) {
        editingMcpId = server.id
        addMcpOpen = true
        mcpName = server.name
        mcpTransport = server.transport
        mcpCommand = server.command
        mcpArgs = McpConfigText.argsLine(server.args)
        mcpEnv = McpConfigText.envLines(server.env)
        mcpUrl = server.url
        mcpHeaders = McpConfigText.headerLines(server.headers)
    }

    func clearMcpForm() {
        editingMcpId = nil
        addMcpOpen = false
        mcpName = ""
        mcpCommand = ""
        mcpArgs = ""
        mcpEnv = ""
        mcpUrl = ""
        mcpHeaders = ""
        mcpTransport = .stdio
    }

    func saveMcpServer() {
        let args = McpConfigText.parseArgs(mcpArgs)
        let env = McpConfigText.parseEnv(mcpEnv)
        let headers = McpConfigText.parseHeaders(mcpHeaders)
        if let id = editingMcpId, var existing = store.mcpServers.first(where: { $0.id == id }) {
            let trimmed = mcpName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            existing.name = trimmed
            existing.transport = mcpTransport
            existing.command = mcpCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            existing.args = args
            existing.env = env
            existing.url = mcpUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            existing.headers = headers
            store.updateMcpServer(existing)
            store.probeMcpServer(existing.id)
            clearMcpForm()
            return
        }
        guard let added = store.addMcpServer(
            name: mcpName,
            transport: mcpTransport,
            command: mcpCommand,
            args: args,
            env: env,
            url: mcpUrl,
            headers: headers
        ) else { return }
        store.probeMcpServer(added.id)
        clearMcpForm()
    }
}
