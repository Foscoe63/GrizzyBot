import GrizzyBotCore
import SwiftUI

struct HostComputerPromptView: View {
    @Environment(AppStore.self) private var store
    @State private var error: String?

    var body: some View {
        ZStack {
            Color(red: 5 / 255, green: 5 / 255, blue: 6 / 255).opacity(0.8)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                Text("Where should bots run?")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Theme.textBrightAlt)

                Text("Docker is the default: each bot gets an isolated Linux desktop with a browser. macOS will not ask for extra permission if you let bots run on this Mac — they run as you.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
                    .lineSpacing(4)
                    .padding(.top, 8)

                if let error {
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.orange)
                        .padding(.top, 10)
                }

                VStack(spacing: 8) {
                    Button {
                        store.setComputerHost("docker")
                    } label: {
                        Text("Docker (recommended)")
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
                        store.setComputerHost("this-mac")
                    } label: {
                        Text("Use this Mac")
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

                Text("This Mac runs shell commands with your account, including files in your home folder. Do not turn it on for a shared or public server.")
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
