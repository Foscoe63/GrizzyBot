import GrizzyBotCore
import SwiftUI

struct OnboardingView: View {
    @Environment(AppStore.self) private var store

    private enum Step {
        case model, bot, questions, done
    }

    @State private var step: Step = .model
    @State private var search = ""
    @State private var selectedProvider = ModelCatalog.defaultProvider
    @State private var selectedModelId = ModelCatalog.defaultModelId
    @State private var apiKey = ""
    @State private var modelError: String?
    @State private var signingIn = false
    @State private var userCode: String?
    @State private var waitingSignIn = false

    @State private var botName = ""
    @State private var botTitle = ""
    @State private var botDescription = ""

    @State private var questionIndex = 0
    @State private var answers: [String] = []

    private let questions: [(title: String, sub: String, options: [String])] = [
        (
            "What do you mainly want help with?",
            "Pick whatever's closest, or type your own.",
            [
                "Inbox & email",
                "Slack & messages",
                "Coding & repos",
                "Research & writing",
                "A bit of everything",
            ]
        ),
        (
            "How do you want me to write?",
            "I'll match this unless you say otherwise.",
            [
                "Clear and tight",
                "Warm and conversational",
                "Polished / formal",
                "Match whatever I draft",
            ]
        ),
    ]

    var body: some View {
        ZStack {
            Theme.bgMain.ignoresSafeArea()
            VStack(spacing: 0) {
                TrafficLightSpacer()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 18)
                    .padding(.top, 16)

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        switch step {
                        case .model: modelStep
                        case .bot: botStep
                        case .questions: questionsStep
                        case .done: doneStep
                        }
                    }
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                    .padding(.top, 48)
                    .padding(.bottom, 80)
                }
                .grizzyScroll()
            }
        }
    }

    // MARK: - Model

    private var filteredProviders: [CatalogEntry] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let providers = ModelCatalog.providers
        guard !q.isEmpty else { return providers }
        return providers.filter { entry in
            let hay = [
                entry.provider,
                entry.providerName ?? "",
                entry.label,
                entry.id,
                entry.billing,
                entry.oauthLabel ?? "",
            ].joined(separator: " ").lowercased()
            return hay.contains(q)
        }
    }

    private var selectedEntry: CatalogEntry? {
        ModelCatalog.models(forProvider: selectedProvider).first(where: { $0.id == selectedModelId })
            ?? ModelCatalog.models(forProvider: selectedProvider).first
    }

    private var modelStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Connect a model")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(Theme.textBrightAlt)

            Text("GrizzyBot does not pay for model usage. Paste an API key, sign in with ChatGPT, Copilot, or SuperGrok, or skip if this deployment already has a key.")
                .font(.system(size: 14.5))
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 10)

            TextField("Search providers and models", text: $search)
                .font(.system(size: 15))
                .foregroundStyle(Theme.textBright)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(Theme.borderInputsDark, lineWidth: 1)
                }
                .padding(.top, 32)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(filteredProviders.enumerated()), id: \.element.provider) { index, entry in
                        Button {
                            selectedProvider = entry.provider
                            if let first = ModelCatalog.models(forProvider: entry.provider).first {
                                selectedModelId = first.id
                            }
                            userCode = nil
                            waitingSignIn = false
                            modelError = nil
                        } label: {
                            HStack {
                                Text(entry.providerName ?? entry.provider)
                                    .font(.system(size: 15))
                                    .foregroundStyle(Theme.textBright)
                                Spacer()
                                Text(ModelCatalog.hint(for: entry))
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(
                                selectedProvider == entry.provider
                                    ? Theme.bgSelectedRow
                                    : Color.clear
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if index < filteredProviders.count - 1 {
                            Divider().background(Theme.borderListRows)
                        }
                    }
                }
            }
            .frame(maxHeight: 192)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(Theme.borderInputsDark, lineWidth: 1)
            }
            .padding(.top, 12)

            Text("Model")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 16)

            GrizzySelect(
                options: ModelCatalog.models(forProvider: selectedProvider).map(\.id),
                selection: $selectedModelId,
                style: .field,
                label: { id in
                    ModelCatalog.models(forProvider: selectedProvider).first(where: { $0.id == id })?.label ?? id
                }
            )
            .padding(.top, 8)

            if let entry = selectedEntry {
                Text(entry.billing)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 8)

                if entry.signIn == .deviceCode {
                    Button {
                        startDeviceCode(for: entry)
                    } label: {
                        Text(signingIn ? "Starting…" : ModelCatalog.signInLabel(for: entry))
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.textCream)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(Theme.bgCream)
                            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(signingIn || waitingSignIn)
                    .padding(.top, 14)

                    if let userCode, waitingSignIn {
                        let uri = ModelCatalog.verificationURI(forProvider: entry.provider)
                            .replacingOccurrences(of: "https://", with: "")
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Enter this code at \(uri)")
                                .font(.system(size: 14))
                                .foregroundStyle(Theme.textBright)
                                .underline()
                            Text(userCode)
                                .font(.system(size: 22, design: .monospaced))
                                .tracking(0.2 * 22 * 0.1)
                                .foregroundStyle(Theme.textBrightAlt)
                            Text("Waiting for sign-in…")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .overlay {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .stroke(Theme.borderInputsDark, lineWidth: 1)
                        }
                        .padding(.top, 12)
                    }
                }

                if entry.auth == .oauth {
                    Text("This provider cannot paste a key here. Skip if this deployment already has credentials.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.top, 12)
                } else {
                    GrizzyField(
                        label: entry.signIn == .deviceCode ? "Or paste an API key" : "API key",
                        placeholder: "sk-…",
                        text: $apiKey,
                        style: .dark,
                        secure: true
                    )
                    .padding(.top, 12)
                }
            }

            if let modelError {
                Text(modelError)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.orange)
                    .padding(.top, 10)
            }

            HStack(spacing: 12) {
                Button {
                    continueModel()
                } label: {
                    Text("Continue")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textCream)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Theme.bgCream)
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    step = .bot
                } label: {
                    Text("Skip for now")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 24)
        }
    }

    private func startDeviceCode(for entry: CatalogEntry) {
        signingIn = true
        modelError = nil
        userCode = ModelCatalog.makeUserCode()
        signingIn = false
        waitingSignIn = true
        Task {
            try? await Task.sleep(for: .seconds(4))
            await MainActor.run {
                waitingSignIn = false
                store.saveModelSelection(
                    provider: entry.provider,
                    modelId: selectedModelId,
                    apiKey: apiKey.isEmpty ? nil : apiKey
                )
                step = .bot
            }
        }
    }

    private func continueModel() {
        guard let entry = selectedEntry else { return }
        if entry.auth != .oauth, entry.auth != .both, apiKey.trimmingCharacters(in: .whitespaces).isEmpty,
           entry.signIn != .deviceCode {
            // Allow continue with empty key (deployment may already have one); no hard error.
        }
        store.saveModelSelection(
            provider: selectedProvider,
            modelId: selectedModelId,
            apiKey: apiKey.isEmpty ? nil : apiKey
        )
        step = .bot
    }

    // MARK: - Bot

    private var botStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Create your first bot")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(Theme.textBrightAlt)

            GrizzyField(placeholder: "Name this bot", text: $botName)
                .padding(.top, 32)
            GrizzyField(placeholder: "Describe what this bot does", text: $botTitle)
                .padding(.top, 12)
            GrizzyField(
                placeholder: "What this bot is for",
                text: $botDescription,
                axis: .vertical,
                lineLimit: 4...8
            )
            .padding(.top, 12)

            Button {
                step = .questions
                questionIndex = 0
            } label: {
                Text("Continue")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textCream)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Theme.bgCream)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .opacity(botName.trimmingCharacters(in: .whitespaces).isEmpty ? 0.45 : 1)
            }
            .buttonStyle(.plain)
            .disabled(botName.trimmingCharacters(in: .whitespaces).isEmpty)
            .padding(.top, 24)
        }
    }

    // MARK: - Questions

    private var questionsStep: some View {
        let q = questions[questionIndex]
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text(q.title)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Theme.textBrightAlt)
                Text(q.sub)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 4)

                VStack(spacing: 0) {
                    ForEach(Array(q.options.enumerated()), id: \.offset) { index, option in
                        Button {
                            answers.append(option)
                            if questionIndex + 1 < questions.count {
                                questionIndex += 1
                            } else {
                                step = .done
                            }
                        } label: {
                            HStack(spacing: 14) {
                                Text(letter(for: index))
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(Theme.textLetter)
                                    .frame(width: 22, height: 22)
                                    .background(Theme.bgLetterBadge)
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                Text(option)
                                    .font(.system(size: 15.5))
                                    .foregroundStyle(Theme.textBright)
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if index < q.options.count - 1 {
                            Divider().background(Theme.borderListRows)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(Theme.borderListRowsAlt, lineWidth: 1)
                }
                .padding(.top, 14)
            }
            .padding(20)
            .background(Theme.bgSelectedRow)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    private func letter(for index: Int) -> String {
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        guard index < letters.count else { return "?" }
        return String(letters[index])
    }

    // MARK: - Done

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("You're set.")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(Theme.textBrightAlt)
            Text("I'll pick up work the moment you send it.")
                .font(.system(size: 15))
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 10)

            Button {
                store.finishOnboarding(
                    name: botName.trimmingCharacters(in: .whitespacesAndNewlines),
                    title: botTitle,
                    description: botDescription,
                    answers: answers
                )
            } label: {
                Text("Open GrizzyBot")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textCream)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Theme.bgCream)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.top, 24)
        }
    }
}
