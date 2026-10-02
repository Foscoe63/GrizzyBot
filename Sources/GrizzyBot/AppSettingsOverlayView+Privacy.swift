import AppKit
import GrizzyBotCore
import SwiftUI
import UniformTypeIdentifiers

extension AppSettingsOverlayView {
    @ViewBuilder
    var privacySection: some View {
        settingsCard(
            title: "Privacy on send",
            subtitle: "Regex PII filter before cloud model calls (GrizzyClaw-style). Critical secrets can fail closed."
        ) {
            Toggle("Enable privacy filter", isOn: Binding(
                get: { store.appConfig.privacyFilter.enabled },
                set: { value in
                    var config = store.appConfig
                    config.privacyFilter.enabled = value
                    store.saveAppConfig(config)
                }
            ))
            .toggleStyle(.switch)
            Toggle("Redact before cloud send", isOn: Binding(
                get: { store.appConfig.privacyFilter.redactBeforeCloudSend },
                set: { value in
                    var config = store.appConfig
                    config.privacyFilter.redactBeforeCloudSend = value
                    store.saveAppConfig(config)
                }
            ))
            .toggleStyle(.switch)
            .padding(.top, 8)
            Toggle("Fail closed on critical PII", isOn: Binding(
                get: { store.appConfig.privacyFilter.failClosed },
                set: { value in
                    var config = store.appConfig
                    config.privacyFilter.failClosed = value
                    store.saveAppConfig(config)
                }
            ))
            .toggleStyle(.switch)
            .padding(.top, 8)
        }

        settingsCard(
            title: "Lean memory",
            subtitle: "Heuristic mode injects Pin/Facts only when the prompt looks memory-relevant."
        ) {
            Picker("Memory inject", selection: Binding(
                get: { store.appConfig.memoryRelevanceMode },
                set: { value in
                    var config = store.appConfig
                    config.memoryRelevanceMode = value
                    store.saveAppConfig(config)
                }
            )) {
                Text("Always (legacy)").tag(MemoryRelevanceGateMode.always)
                Text("Heuristic").tag(MemoryRelevanceGateMode.heuristic)
                Text("Off").tag(MemoryRelevanceGateMode.off)
            }
            .pickerStyle(.menu)
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
            Toggle("Enable local gateway", isOn: Binding(
                get: { store.appConfig.localGateway.enabled },
                set: { value in
                    var config = store.appConfig
                    config.localGateway.enabled = value
                    if let port = Int(gatewayPort) { config.localGateway.port = port }
                    config.localGateway.apiKey = gatewayKey
                    store.saveAppConfig(config)
                }
            ))
            .toggleStyle(.switch)
            GrizzyField(label: "Port", placeholder: "8787", text: $gatewayPort)
                .padding(.top, 8)
            GrizzyField(label: "API key (optional Bearer)", placeholder: "local-secret", text: $gatewayKey, secure: true)
                .padding(.top, 8)
            GrizzyButton(title: "Save gateway", variant: .cream, size: .sm) {
                var config = store.appConfig
                if let port = Int(gatewayPort) { config.localGateway.port = port }
                config.localGateway.apiKey = gatewayKey
                store.saveAppConfig(config)
                sessionNotice = config.localGateway.enabled
                    ? "Gateway listening on port \(config.localGateway.port)"
                    : "Gateway disabled"
            }
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
                }
            )
            GrizzyButton(title: "Save Sentry DSN", variant: .cream, size: .sm) {
                store.applySecret(.sentry, input: sentryDSN)
                CrashReporting.startSentry(dsn: store.appConfig.sentryDSN)
                sentryDSN = ""
                sessionNotice = store.appConfig.sentryConfigured
                    ? "Sentry is on"
                    : "Sentry DSN cleared — local crash file only"
            }
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
