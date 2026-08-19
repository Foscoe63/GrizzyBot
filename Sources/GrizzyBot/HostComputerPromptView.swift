import GrizzyBotCore
import SwiftUI

struct HostComputerPromptView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        ZStack {
            Color(red: 5 / 255, green: 5 / 255, blue: 6 / 255).opacity(0.8)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                Text("How should bots use the computer?")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Theme.textBrightAlt)

                Text("GrizzyBot supports an in-app browser (cookies can persist per bot) or controlling this Mac with Accessibility and Screen Recording. Cloud VMs and Docker are not available yet.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
                    .lineSpacing(4)
                    .padding(.top, 8)

                VStack(spacing: 8) {
                    Button {
                        store.setComputerHost(ComputerHost.inAppBrowser.rawValue)
                    } label: {
                        Text("In-app browser (recommended)")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.textCream)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(Theme.bgCream)
                            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    Button {
                        store.setComputerHost(ComputerHost.thisMac.rawValue)
                    } label: {
                        Text("This Mac")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.textBright)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .overlay {
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .stroke(Theme.borderInputsDark, lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 20)

                Text("This Mac runs shell commands and UI automation with your account. Only enable it on a machine you control.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
                    .lineSpacing(3)
                    .padding(.top, 12)
            }
            .padding(24)
            .frame(width: 440)
            .background(Theme.bgHostCard)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Theme.borderInputsDark, lineWidth: 1)
            }
        }
    }
}
