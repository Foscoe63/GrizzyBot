import GrizzyBotCore
import SwiftUI

struct WelcomeView: View {
    @Environment(AppStore.self) private var store
    @State private var hoverSignIn = false

    var body: some View {
        ZStack {
            Theme.bgWelcome.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    TrafficLightSpacer()
                    Spacer()
                }
                .padding(.leading, 18)
                .padding(.top, 16)

                Spacer(minLength: 0)

                VStack(spacing: 44) {
                    HStack(spacing: 26) {
                        ZStack {
                            Circle()
                                .fill(Theme.bgWelcomeLogo)
                                .frame(width: 88, height: 88)
                            HStack(spacing: 13) {
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .fill(Theme.bgLogoBars)
                                    .frame(width: 11, height: 24)
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .fill(Theme.bgLogoBars)
                                    .frame(width: 11, height: 24)
                            }
                        }
                        Text("GrizzyBot")
                            .font(.system(size: 76, weight: .regular))
                            .tracking(-0.03 * 76)
                            .foregroundStyle(.white)
                    }

                    VStack(spacing: 4) {
                        Text("Your team of always-on agents")
                        Text("that you can give real work to.")
                    }
                    .font(.system(size: 27))
                    .foregroundStyle(Theme.textWelcomeTagline)
                    .multilineTextAlignment(.center)

                    Button {
                        store.goToSignIn()
                    } label: {
                        Text("Sign in  →")
                            .font(.system(size: 19))
                            .foregroundStyle(Theme.textPill)
                            .padding(.horizontal, 34)
                            .padding(.vertical, 15)
                            .background(hoverSignIn ? Theme.bgDarkButtonHover : Theme.bgDarkButtonAlt)
                            .clipShape(Capsule())
                            .scaleEffect(hoverSignIn ? 1.04 : 1)
                    }
                    .buttonStyle(.plain)
                    .onHover { hoverSignIn = $0 }
                    .animation(.easeOut(duration: 0.15), value: hoverSignIn)

                    if !store.registeredAccounts.isEmpty {
                        VStack(spacing: 10) {
                            Text("Or continue as")
                                .font(.system(size: 14))
                                .foregroundStyle(Theme.textWelcomeTagline.opacity(0.8))
                            ForEach(store.registeredAccounts.filter { $0.email != "local@grizzybot.local" }.prefix(3)) { account in
                                Button(account.name) {
                                    store.goToSignIn(email: account.email)
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 15))
                                .foregroundStyle(Theme.textWelcomeTagline)
                            }
                            Button("Local workspace") {
                                store.continueAsLocalUser()
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.textWelcomeTagline.opacity(0.9))
                        }
                        .padding(.top, 8)
                    } else {
                        Button("Continue without signing in") {
                            store.continueAsLocalUser()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textWelcomeTagline.opacity(0.9))
                        .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity)

                Spacer(minLength: 0)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
