import AppKit
import GrizzyBotCore
import SwiftUI

/// The original message and its scrubbed version side by side, with the sensitive parts marked.
struct RedactionPreviewView: View {
    let preview: RedactionPreview

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            column(title: "As you wrote it", scrubbed: false)
            column(title: "What the model gets", scrubbed: true)
        }
    }

    private func column(title: String, scrubbed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textMuted)
            ScrollView {
                text(scrubbed: scrubbed)
                    .font(.system(size: 12.5))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(minHeight: 70, maxHeight: 180)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.12)))
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func text(scrubbed: Bool) -> Text {
        preview.segments.reduce(Text("")) { acc, seg in
            if seg.isRedacted {
                let shown = scrubbed ? (seg.replacement ?? "") : seg.original
                return acc + Text(shown).foregroundColor(Theme.orange).bold()
            }
            return acc + Text(seg.original)
        }
    }
}

/// Shown before a message that contains personal data leaves, when "Review before sending" is on.
struct PrivacyReviewSheet: View {
    let preview: RedactionPreview
    var onSendScrubbed: () -> Void
    var onSendAsWritten: () -> Void
    var onCancel: () -> Void

    private var kinds: String {
        Array(Set(preview.segments.compactMap { $0.type?.displayName })).sorted().joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("This message has personal data")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.textBright)
            Text("Found: \(kinds). Placeholders replace them on the way out and are put back in the reply.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            RedactionPreviewView(preview: preview)
            HStack {
                GrizzyButton(title: "Cancel", variant: .cream, size: .sm, action: onCancel)
                Spacer()
                GrizzyButton(title: "Send as written", variant: .cream, size: .sm, action: onSendAsWritten)
                GrizzyButton(title: "Send scrubbed", variant: .cream, size: .sm, action: onSendScrubbed)
            }
        }
        .padding(20)
        .frame(width: 620)
    }
}

/// On-device detection, review-before-send, the never-redact list, and a place to try the rules.
struct PrivacyAdvancedBlock: View {
    @Environment(AppStore.self) private var store
    @State private var neverRedact = ""
    @State private var sample = "Email ada@example.com or call 415-555-0134. Ask Tim Cook in Cupertino."

    private func update(_ change: (inout PrivacyFilterSettings) -> Void) {
        var config = store.appConfig
        change(&config.privacyFilter)
        store.saveAppConfig(config)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsToggle(title: "Find names, places and organisations", isOn: Binding(
                get: { store.appConfig.privacyFilter.useOnDeviceNER },
                set: { value in update { $0.useOnDeviceNER = value } }
            ))
            Text("Uses Apple's language model on this Mac; nothing leaves it. It can flag a product or a city you didn't mean.")
                .font(.system(size: 12)).foregroundStyle(Theme.textMuted)
            SettingsToggle(title: "Review before sending", isOn: Binding(
                get: { store.appConfig.privacyFilter.reviewBeforeSend },
                set: { value in update { $0.reviewBeforeSend = value } }
            ))
            GrizzyField(label: "Never redact (comma separated)", placeholder: "Acme, support@acme.com", text: $neverRedact, onCommit: saveNever)
            GrizzyButton(title: "Save list", variant: .cream, size: .sm) { saveNever() }

            Text("Try it").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textBright).padding(.top, 6)
            GrizzyField(placeholder: "Type something to scrub", text: $sample, axis: .vertical, lineLimit: 2...4)
            let preview = RedactionPreview.make(for: sample, settings: store.appConfig.privacyFilter, session: RedactionSession())
            if preview.segments.contains(where: \.isRedacted) {
                RedactionPreviewView(preview: preview)
            } else {
                Text("Nothing in that would be scrubbed.").font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
            }
        }
        .onAppear { neverRedact = store.appConfig.privacyFilter.neverRedact.joined(separator: ", ") }
    }

    private func saveNever() {
        let items = neverRedact.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        update { $0.neverRedact = items }
    }
}

/// Every settings change, from the person or from a bot, with a one-click undo.
struct ConfigHistoryBlock: View {
    @Environment(AppStore.self) private var store
    @State private var notice: String?
    @State private var revision = 0

    private static func recent(_ store: AppStore, whenConfig _: AppConfig) -> [ConfigChange] {
        Array(store.configHistory().suffix(8).reversed())
    }

    var body: some View {
        // Reading appConfig makes this re-read the history whenever settings change.
        let entries = Self.recent(store, whenConfig: store.appConfig)
        VStack(alignment: .leading, spacing: 8) {
            if entries.isEmpty {
                Text("No changes recorded yet.").font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
            }
            ForEach(entries) { entry in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.readable).font(.system(size: 12.5)).foregroundStyle(Theme.textBright).lineLimit(2)
                        Text("\(entry.at.formatted(date: .abbreviated, time: .shortened)) · \(entry.source)")
                            .font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                    }
                    Spacer()
                    if entry.revertible {
                        GrizzyButton(title: "Undo", variant: .cream, size: .sm) {
                            notice = store.revertConfigChange(id: entry.id) ? "Undone." : "That change couldn't be undone."
                            revision += 1
                        }
                    }
                }
            }
            if let notice { Text(notice).font(.system(size: 12)).foregroundStyle(Theme.textSecondary) }
        }
        .id(revision)
    }
}

/// Opt-in encryption of the account's files on disk, with a recovery key.
struct StorageEncryptionBlock: View {
    @Environment(AppStore.self) private var store
    @State private var notice: String?
    @State private var recoveryInput = ""
    @State private var revealed: [String: String]?
    @State private var on = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsToggle(title: "Encrypt data on this Mac", isOn: Binding(
                get: { on },
                set: { value in notice = store.setStorageEncryption(value); on = store.storageEncryptionEnabled }
            ))
            Text("Off by default; FileVault already protects the disk. If you turn this on, keep the recovery key: without it, a new Mac or a wiped Keychain can't open your data.")
                .font(.system(size: 12)).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
            if on {
                GrizzyButton(title: revealed == nil ? "Show recovery key" : "Hide recovery key", variant: .cream, size: .sm) {
                    revealed = revealed == nil ? store.storageRecoveryKeys() : nil
                }
                if let revealed {
                    ForEach(revealed.sorted(by: { $0.key < $1.key }), id: \.key) { name, key in
                        Text("\(name): \(key)").font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            if store.storageNeedsRecovery {
                Text("Your data is encrypted but its key isn't in the Keychain. Paste a recovery key to open it.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.orange)
                GrizzyField(placeholder: "Recovery key", text: $recoveryInput, secure: true)
                GrizzyButton(title: "Recover", variant: .cream, size: .sm) {
                    notice = store.recoverStorage(key: recoveryInput) ? "Key restored. Restart GrizzyBot." : "That key doesn't match."
                }
            }
            if let notice { Text(notice).font(.system(size: 12)).foregroundStyle(Theme.textSecondary) }
        }
        .onAppear { on = store.storageEncryptionEnabled }
    }
}

/// The phrase hands-free listening waits for.
struct HandsFreePhraseBlock: View {
    @AppStorage(HandsFreeListener.phraseKey) private var phrase = HandsFreeListener.defaultPhrase

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GrizzyField(label: "Wake phrase", placeholder: HandsFreeListener.defaultPhrase, text: $phrase)
            Text("Pick two or more syllables so it isn't set off by ordinary talk. Leave it empty to use “\(HandsFreeListener.defaultPhrase)”.")
                .font(.system(size: 12)).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The workflows saved in this account, each with inputs and a Run button that uses the active bot.
struct WorkflowsListBlock: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let flows = store.workflows()
        VStack(alignment: .leading, spacing: 14) {
            if flows.isEmpty {
                Text("None yet. A workflow is a JSON file in the workflows folder of your GrizzyBot folder; ask a bot to draft one.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(flows) { flow in WorkflowRow(flow: flow) }
        }
    }
}

private struct WorkflowRow: View {
    @Environment(AppStore.self) private var store
    let flow: WorkflowDefinition
    @State private var values: [String: String] = [:]
    @State private var running = false
    @State private var result: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(flow.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textBright)
            Text("\(flow.nodes.count) steps" + (flow.summary.isEmpty ? "" : " · " + flow.summary))
                .font(.system(size: 11.5)).foregroundStyle(Theme.textMuted)
            ForEach(flow.inputs.keys.sorted(), id: \.self) { key in
                GrizzyField(label: key, placeholder: flow.inputs[key] ?? "", text: Binding(
                    get: { values[key] ?? flow.defaults[key] ?? "" },
                    set: { values[key] = $0 }
                ))
            }
            HStack {
                GrizzyButton(title: running ? "Running…" : "Run as \(store.activeBot?.name ?? "a bot")", variant: .cream, size: .sm) { run() }
                    .disabled(running || store.activeBot == nil)
            }
            if let result {
                Text(result).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func run() {
        guard let bot = store.activeBot else { return }
        running = true
        var input = flow.defaults
        for (k, v) in values where !v.isEmpty { input[k] = v }
        Task {
            let text = await store.runWorkflow(id: flow.id, input: input, botId: bot.id)
            result = text
            running = false
        }
    }
}
