import GrizzyBotCore
import SwiftUI

struct RootView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Group {
            switch store.route {
            case .welcome:
                WelcomeView()
            case .signIn:
                AuthView(mode: .signIn)
            case .signUp:
                AuthView(mode: .signUp)
            case .onboarding:
                OnboardingView()
            case .shell:
                ShellView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
