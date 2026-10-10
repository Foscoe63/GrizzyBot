import AppKit
import GrizzyBotCore
import SwiftUI

/// Per-routine switches that are not part of the schedule: remembering the last report,
/// quiet heartbeat mode, and the webhook.
struct RoutineTriggerOptions: View {
    @Environment(AppStore.self) private var store
    let routineId: String

    @State private var shownSecret: String?
    @State private var copied = false

    private var routine: Routine? {
        store.routines.values.flatMap { $0 }.first { $0.id == routineId }
    }

    var body: some View {
        if let routine {
            VStack(alignment: .leading, spacing: 10) {
                Text("Options")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)

                Toggle(isOn: Binding(
                    get: { routine.continuity },
                    set: { store.setRoutineOptions(routineId, continuity: $0) }
                )) {
                    optionLabel("Remember the last report", "Each run sees the previous one, so it can say only what's new.")
                }

                Toggle(isOn: Binding(
                    get: { routine.heartbeat },
                    set: { store.setRoutineOptions(routineId, heartbeat: $0) }
                )) {
                    optionLabel("Heartbeat", "Treat the instruction as a checklist. If nothing needs you, the chat stays quiet.")
                }

                Toggle(isOn: Binding(
                    get: { routine.webhookEnabled },
                    set: { on in
                        if on {
                            shownSecret = store.enableWebhook(routineId: routineId)
                        } else {
                            store.disableWebhook(routineId: routineId)
                            shownSecret = nil
                        }
                    }
                )) {
                    optionLabel("Webhook", "Let another program start this routine with an HTTP POST.")
                }

                if routine.webhookEnabled {
                    webhookDetails
                }
            }
            .toggleStyle(.switch)
            .padding(.top, 18)
        }
    }

    @ViewBuilder
    private var webhookDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !store.appConfig.webhooksEnabled {
                Text("The webhook listener is off. Turn it on in Settings → Connections → Webhooks.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.orange)
            }
            Text(store.webhookURL(routineId: routineId))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.textBright)
                .textSelection(.enabled)
            if let secret = shownSecret {
                Text("Secret — shown once, copy it now:")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)
                Text(secret)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.textBright)
                    .textSelection(.enabled)
                GrizzyButton(title: copied ? "Copied" : "Copy secret", variant: .cream, size: .sm) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(secret, forType: .string)
                    copied = true
                }
            } else {
                GrizzyButton(title: "New secret", variant: .cream, size: .sm) {
                    shownSecret = store.rotateWebhookSecret(routineId: routineId)
                    copied = false
                }
            }
            Text("Send it as `Authorization: Bearer <secret>`. The body is passed to the bot as untrusted data.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
        }
        .padding(.leading, 4)
    }

    private func optionLabel(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 14))
                .foregroundStyle(Theme.textBright)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
