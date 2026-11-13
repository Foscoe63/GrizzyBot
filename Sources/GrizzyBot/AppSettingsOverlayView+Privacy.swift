import AppKit
import GrizzyBotCore
import SwiftUI
import UniformTypeIdentifiers

extension AppSettingsOverlayView {
    @ViewBuilder
    var privacySection: some View {
        settingsCard(
            title: "Privacy on send",
            subtitle: "Regex PII filter before cloud model calls. Critical secrets can fail closed."
        ) {
            settingsToggle("Privacy filter", "Scan outgoing prompts for personal data.", isOn: Binding(
                get: { store.appConfig.privacyFilter.enabled },
                set: { value in updateConfig { $0.privacyFilter.enabled = value } }
            ))
            settingsToggle("Redact before cloud send", "Replace matches with placeholders instead of sending them.", isOn: Binding(
                get: { store.appConfig.privacyFilter.redactBeforeCloudSend },
                set: { value in updateConfig { $0.privacyFilter.redactBeforeCloudSend = value } }
            ))
            .disabled(!store.appConfig.privacyFilter.enabled)
            settingsToggle("Fail closed on critical PII", "Block the send entirely when a key or card number is found.", isOn: Binding(
                get: { store.appConfig.privacyFilter.failClosed },
                set: { value in updateConfig { $0.privacyFilter.failClosed = value } }
            ))
            .disabled(!store.appConfig.privacyFilter.enabled)
        }

        settingsCard(
            title: "Lean memory",
            subtitle: "Heuristic mode injects Pin/Facts only when the prompt looks memory-relevant."
        ) {
            SettingsRow(title: "Memory inject") {
                SettingsSegmented(
                    options: [(MemoryRelevanceGateMode.always, "Always"), (.heuristic, "Heuristic"), (.off, "Off")],
                    selection: Binding(
                        get: { store.appConfig.memoryRelevanceMode },
                        set: { value in updateConfig { $0.memoryRelevanceMode = value } }
                    )
                )
            }
            if let botId = store.activeBotId {
                let clusters = store.memoryDedupeClusters(botId: botId)
                Text(clusters.isEmpty ? "No near-duplicate Facts for the active bot." : "\(clusters.count) duplicate cluster(s) found.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 10)
                if !clusters.isEmpty {
                    GrizzyButton(title: "Merge duplicates", variant: .cream, size: .sm) {
                        let removed = store.mergeMemoryDuplicates(botId: botId)
                        sessionNotice = "Removed \(removed.count) duplicate fact(s)."
                    }
                    .padding(.top, 8)
                }
            }
        }

        settingsCard(
            title: "Local OpenAI / MCP gateway",
            subtitle: "Expose bots at http://127.0.0.1:PORT/v1/chat/completions and /mcp/tools for Cursor."
        ) {
            settingsToggle("Local gateway", "Serves bots over loopback for Cursor and other clients.", isOn: Binding(
                get: { store.appConfig.localGateway.enabled },
                set: { value in
                    updateConfig { config in
                        config.localGateway.enabled = value
                        if let port = Self.validPort(gatewayPort) { config.localGateway.port = port }
                        config.localGateway.apiKey = gatewayKey
                    }
                }
            ))
            GrizzyField(label: "Port", placeholder: "8787", text: $gatewayPort, onCommit: { saveGateway() })
                .padding(.top, 8)
            GrizzyField(label: "API key (optional Bearer)", placeholder: "local-secret", text: $gatewayKey, secure: true, onCommit: { saveGateway() })
                .padding(.top, 8)
            GrizzyButton(title: "Save gateway", variant: .cream, size: .sm) { saveGateway() }
                .padding(.top, 10)
        }
    }

    @ViewBuilder
    var watchersSection: some View {
        settingsCard(
            title: "Folder watchers",
            subtitle: "Each watcher is a card. Select one to edit, run it now, or delete it. FSEvents still fire while this is enabled."
        ) {
            FolderWatchersSettingsBlock()
        }

        settingsCard(
            title: "MCP Bonjour",
            subtitle: "Discover `_mcp._tcp` services on the local network (e.g. MacUse)."
        ) {
            GrizzyButton(title: "Browse LAN", variant: .cream, size: .sm) {
                Task {
                    bonjourHits = await store.discoverMcpBonjour()
                }
            }
            if bonjourHits.isEmpty {
                Text("No results yet.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 8)
            } else {
                ForEach(bonjourHits) { hit in
                    Text("\(hit.name) — \(hit.httpBaseURL)")
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                        .padding(.top, 6)
                }
            }
        }
    }

    @ViewBuilder
    var diagnosticsSection: some View {
        settingsCard(
            title: "Crash reporting",
            subtitle: "Sentry receives crashes when a DSN is saved. last-crash.txt is always written locally under Diagnostics."
        ) {
            secretRow(
                title: "Sentry DSN",
                configured: store.appConfig.sentryConfigured,
                text: $sentryDSN,
                onClear: {
                    store.clearSecret(.sentry)
                    CrashReporting.install(dsn: nil)
                },
                onCommit: { saveSentry() }
            )
            GrizzyButton(title: "Save Sentry DSN", variant: .cream, size: .sm) { saveSentry() }
                .padding(.top, 12)
        }

        settingsCard(
            title: "Agent memory (ai-memory)",
            subtitle: "Bots send sanitized run events to a local ai-memory server. If nothing is being captured, check here."
        ) {
            if let probe = memoryProbe {
                Text(memoryStatusText(probe))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Not checked yet.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)
            }
            GrizzyButton(title: memoryChecking ? "Checking…" : "Check connection", variant: .cream, size: .sm) {
                memoryChecking = true
                Task {
                    memoryProbe = await AiMemoryBridge.probe()
                    memoryChecking = false
                }
            }
            .padding(.top, 10)
        }

        settingsCard(
            title: "Last run log",
            subtitle: "Tool calls, MCP stderr, and agent errors from this session. Copy this when a run fails."
        ) {
            Text(store.lastRunLogText())
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 12) {
                GrizzyButton(title: "Copy last run log", variant: .cream, size: .sm) {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(store.lastRunLogText(), forType: .string)
                    sessionNotice = "Copied run log"
                }
                Button("Copy last crash") {
                    if let text = CrashReporting.latestCrashText() {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(DiagnosticScrubber.redact(text), forType: .string)
                        sessionNotice = "Copied crash log"
                    } else {
                        sessionNotice = "No crash log yet"
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSidebarIcon)
            }
            .padding(.top, 10)
            Button("Open diagnostics folder") {
                NSWorkspace.shared.open(store.diagnosticsDirectory())
            }
            .buttonStyle(.plain)
            .font(.system(size: 12.5))
            .foregroundStyle(Theme.textSidebarIcon)
            .padding(.top, 8)
        }
    }

    func saveSentry() {
        store.applySecret(.sentry, input: sentryDSN)
        CrashReporting.startSentry(dsn: store.appConfig.sentryDSN)
        sentryDSN = ""
        sessionNotice = store.appConfig.sentryConfigured ? "Sentry is on" : "Sentry DSN cleared — local crash file only"
    }

    static func validPort(_ text: String) -> Int? {
        guard let port = Int(text.trimmingCharacters(in: .whitespaces)), (1024...65_535).contains(port) else { return nil }
        return port
    }

    func saveGateway() {
        guard let port = Self.validPort(gatewayPort) else {
            sessionNotice = "Port must be a number between 1024 and 65535."
            gatewayPort = "\(store.appConfig.localGateway.port)"
            return
        }
        updateConfig { config in
            config.localGateway.port = port
            config.localGateway.apiKey = gatewayKey
        }
        sessionNotice = store.appConfig.localGateway.enabled ? "Gateway listening on port \(port)" : "Gateway saved. Turn it on to start listening."
    }

    func memoryStatusText(_ probe: AiMemoryBridge.Probe) -> String {
        func describe(_ health: AiMemoryBridge.Health) -> String {
            switch health {
            case .connected: return "connected"
            case .backingOff(_, let reason): return reason
            case .unknown: return "no events sent yet"
            }
        }
        guard probe.enabled else { return "Capture is off (GRIZZYBOT_AI_MEMORY=0)." }
        let token: String
        switch probe.tokenSource {
        case .environment: token = "from AI_MEMORY_AUTH_TOKEN"
        case .keychain: token = "from the Keychain"
        case .none: token = "none set"
        }
        return "Server \(probe.server): \(describe(probe.health))\nToken: \(token)\nLast agent run: \(describe(probe.lastRun))"
    }
}
