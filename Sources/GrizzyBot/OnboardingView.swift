import GrizzyBotCore
import SwiftUI

struct OnboardingView: View {
    @Environment(AppStore.self) private var store

    private enum Step {
        case model, bot, questions, done
    }

    @State private var step: Step = .model

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

    private var modelStep: some View {
        ModelConnectView(
            onContinue: { step = .bot },
            onSkip: { step = .bot },
            showSkip: true
        )
    }

    // MARK: - Bot

    private var botStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Create your first bot")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(Theme.textBrightAlt)

            GrizzyField(label: "Name", placeholder: "Name this bot", text: $botName)
                .padding(.top, 32)
            GrizzyField(label: "Title", placeholder: "Describe what this bot does", text: $botTitle)
                .padding(.top, 12)
            GrizzyField(
                label: "Description",
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
