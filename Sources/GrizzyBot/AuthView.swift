import GrizzyBotCore
import SwiftUI

enum AuthMode {
    case signIn
    case signUp
}

struct AuthView: View {
    let mode: AuthMode
    @Environment(AppStore.self) private var store

    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var error: String?
    @State private var pending = false
    @State private var hoverSubmit = false

    var body: some View {
        ZStack {
            Theme.bgAuth.ignoresSafeArea()
            VStack(spacing: 0) {
                TrafficLightSpacer()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 18)
                    .padding(.top, 16)

                Spacer(minLength: 40)

                VStack(alignment: .leading, spacing: 0) {
                    ZStack {
                        Circle()
                            .fill(Theme.bgLogoDark)
                            .frame(width: 74, height: 74)
                        HStack(spacing: 11) {
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(Theme.bgAuth)
                                .frame(width: 9, height: 20)
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(Theme.bgAuth)
                                .frame(width: 9, height: 20)
                        }
                    }

                    Text(mode == .signIn ? "Sign in to GrizzyBot" : "Create your GrizzyBot")
                        .font(.system(size: 38, weight: .regular))
                        .tracking(-0.02 * 38)
                        .foregroundStyle(Theme.textAuthTitle)
                        .padding(.top, 30)
                        .padding(.bottom, 38)

                    VStack(alignment: .leading, spacing: 16) {
                        if mode == .signUp {
                            GrizzyField(
                                label: "Name",
                                placeholder: "Your name",
                                text: $name,
                                style: .auth
                            )
                        }
                        GrizzyField(
                            label: "Email",
                            placeholder: "Your email address",
                            text: $email,
                            style: .auth
                        )
                        GrizzyField(
                            label: "Password",
                            placeholder: "Password",
                            text: $password,
                            style: .auth,
                            secure: true
                        )
                    }

                    if let error {
                        Text(error)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.redError)
                            .padding(.top, 14)
                    }

                    Button {
                        submit()
                    } label: {
                        Text(pending ? "Working…" : (mode == .signIn ? "Continue with email" : "Create account"))
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(Theme.textButton)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18)
                            .background(hoverSubmit ? Theme.bgDarkButtonHover : Theme.bgDarkButton)
                            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(pending)
                    .padding(.top, 18)
                    .onHover { hoverSubmit = $0 }

                    HStack(spacing: 4) {
                        Text(mode == .signIn ? "Don't have an account?" : "Already have an account?")
                            .foregroundStyle(Theme.textAuthFooter)
                        Button {
                            if mode == .signIn {
                                store.goToSignUp()
                            } else {
                                store.goToSignIn()
                            }
                        } label: {
                            Text(mode == .signIn ? "Sign up" : "Sign in")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(Theme.textAuthTitle)
                        }
                        .buttonStyle(.plain)
                    }
                    .font(.system(size: 16))
                    .padding(.top, 30)
                }
                .frame(maxWidth: 460)
                .padding(.horizontal, 24)

                Spacer()
            }
        }
        .onAppear {
            if email.isEmpty, !store.pendingAuthEmail.isEmpty {
                email = store.pendingAuthEmail
            }
        }
    }

    private func submit() {
        pending = true
        error = nil
        let result: String?
        if mode == .signIn {
            result = store.signIn(email: email, password: password)
        } else {
            result = store.signUp(name: name, email: email, password: password)
        }
        pending = false
        error = result
    }
}
