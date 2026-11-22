import AppKit
import GrizzyBotCore
import SwiftUI

/// A bot's Private desktop screen, as polled pictures. Looking never starts the container: a stopped desktop says so, and
/// the person starts it from the controls beside it.
struct PrivateDesktopScreen: View {
    @Environment(AppStore.self) private var store
    let botId: String
    var fill: Bool = false
    var pollSeconds: Double = 4

    var body: some View {
        let state = store.privateDesktopState(botId: botId)
        ZStack {
            if let data = state.frame, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: fill ? .fill : .fit)
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    .clipped()
            } else {
                Theme.bgScreen
                VStack(spacing: 8) {
                    if state.working != nil { ProgressView().controlSize(.small) }
                    Text(state.working ?? PrivateDesktopCopy.idleLine(state.status))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textMuted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                }
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .clipped()
        .task(id: botId) {
            while !Task.isCancelled {
                if store.privateDesktopState(botId: botId).working == nil {
                    await store.refreshPrivateDesktop(botId: botId)
                }
                try? await Task.sleep(for: .seconds(pollSeconds))
            }
        }
    }
}

enum PrivateDesktopCopy {
    /// What to say in place of a picture, from what Podman reports.
    static func idleLine(_ status: PodmanDesktopStatus?) -> String {
        guard let status else { return "Looking for the Private desktop…" }
        if let problem = status.problem { return problem }
        switch status.container {
        case .missing: return "The Private desktop starts the first time the bot uses it, or when you start it."
        case .stopped: return "The Private desktop is stopped."
        case .running: return "Waiting for the desktop's screen…"
        }
    }
}

/// Start, Stop and Reset for one bot's desktop, with what is wrong in words when something is.
struct PrivateDesktopControls: View {
    @Environment(AppStore.self) private var store
    let botId: String

    var body: some View {
        let state = store.privateDesktopState(botId: botId)
        let status = state.status
        let busy = state.working != nil
        VStack(alignment: .leading, spacing: 10) {
            Text(state.working ?? caption(status))
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = state.error {
                Text(error)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if status?.imagePresent == false, status?.machineRunning == true {
                PrivateDesktopImageButton()
            } else {
                HStack(spacing: 10) {
                    if status?.container == .running {
                        GrizzyButton(title: "Stop", variant: .outline, size: .sm, disabled: busy) {
                            store.stopPrivateDesktop(botId: botId)
                        }
                    } else {
                        GrizzyButton(title: "Start", variant: .outline, size: .sm,
                                     disabled: busy || status?.podmanPath == nil || status?.machineRunning != true) {
                            store.startPrivateDesktop(botId: botId)
                        }
                    }
                    if status?.container != .missing && status != nil {
                        GrizzyButton(title: "Reset", variant: .outline, size: .sm, disabled: busy) {
                            store.resetPrivateDesktop(botId: botId)
                        }
                        .help("Removes this desktop so the next start is a fresh one. The bot's workspace folder is kept.")
                    }
                }
            }
            Text("Preview only. This is a separate Linux desktop that cannot see your Mac’s files.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func caption(_ status: PodmanDesktopStatus?) -> String {
        guard let status else { return "Private desktop" }
        if status.ready { return "Private desktop · running" }
        if status.container == .stopped { return "Private desktop · stopped" }
        return "Private desktop"
    }
}

/// Builds the desktop image once. It downloads over 1 GB, so it is a button, never a side effect of a bot's turn.
struct PrivateDesktopImageButton: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.privateDesktopImageWorking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Downloading and building the desktop. This can take several minutes.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                GrizzyButton(title: "Build desktop image (about 1.3 GB)", variant: .cream, size: .sm) {
                    store.buildPrivateDesktopImage()
                }
            }
            if let error = store.privateDesktopImageError {
                Text(error)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
