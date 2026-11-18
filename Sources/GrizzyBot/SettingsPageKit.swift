import GrizzyBotCore
import SwiftUI

/// One settings line: title and explanation on the left, the control on the right.
struct SettingsRow<Control: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textBright)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 16)
            control()
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.borderMainHdr).frame(height: 1)
        }
    }
}

/// Pill-shaped switcher for a short list of options.
struct SettingsSegmented<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Button {
                    selection = option.value
                } label: {
                    Text(option.label)
                        .font(.system(size: 13, weight: selection == option.value ? .medium : .regular))
                        .foregroundStyle(selection == option.value ? Theme.textBright : Theme.textSecondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(selection == option.value ? Theme.bgSelectedRow : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Theme.bgChip)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

extension AppStore.AppSettingsSection {
    /// Which left-rail group the section sits under.
    var railGroup: String {
        switch self {
        case .general, .themes, .privacy, .voice: return "Settings"
        case .computer, .folders, .watchers: return "This computer"
        case .tools, .components, .knowledge, .connections: return "Customize"
        case .governance, .diagnostics: return "Platform"
        }
    }

    static let railGroups = ["Settings", "This computer", "Customize", "Platform"]
}

extension AppSettingsOverlayView {
    /// Read-modify-write on the app config; every setting goes through here so it saves and applies live.
    func updateConfig(_ change: (inout AppConfig) -> Void) {
        var config = store.appConfig
        change(&config)
        store.saveAppConfig(config)
    }

    func settingsToggle(_ title: String, _ subtitle: String? = nil, isOn: Binding<Bool>) -> some View {
        SettingsRow(title: title, subtitle: subtitle) {
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }

    func configToggle(
        _ title: String,
        _ subtitle: String? = nil,
        _ keyPath: WritableKeyPath<AppConfig, Bool>,
        also: ((Bool) -> Void)? = nil
    ) -> some View {
        settingsToggle(title, subtitle, isOn: Binding(
            get: { store.appConfig[keyPath: keyPath] },
            set: { value in
                updateConfig { $0[keyPath: keyPath] = value }
                also?(value)
            }
        ))
    }
}

/// A `SettingsRow` with a switch, for views outside the overlay.
struct SettingsToggle: View {
    let title: String
    var subtitle: String?
    @Binding var isOn: Bool

    init(title: String, subtitle: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.subtitle = subtitle
        self._isOn = isOn
    }

    var body: some View {
        SettingsRow(title: title, subtitle: subtitle) {
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }
}
