import GrizzyBotCore
import SwiftUI

/// Settings → Tools → External coding agents: the built-in agents, the ones you added, and a form to add more.
struct ExternalAgentsBlock: View {
    @Environment(AppStore.self) private var store
    @State private var adding = false
    @State private var name = ""
    @State private var commandLine = ""
    @State private var problem: String?
    @State private var testing: Set<String> = []
    @State private var results: [String: TestResult] = [:]
    @State private var lmModels: [LMStudioModels.Loaded] = []

    private struct TestResult {
        var ok: Bool
        var text: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(ExternalAgentSpec.all(custom: store.externalAgents)) { spec in
                row(spec)
                Divider().overlay(Theme.borderListRowsAlt)
            }

            Button {
                adding.toggle()
                problem = nil
            } label: {
                HStack {
                    Text("Add an agent")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textBright)
                    Spacer()
                    Text(adding ? "▾" : "▸")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textMuted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 10)

            if adding { form.padding(.top, 10) }
        }
        .task { lmModels = await LMStudioModels.loaded() }
    }

    private func row(_ spec: ExternalAgentSpec) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(spec.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textBright)
                if ExternalAgentSpec.isPreset(spec.id) {
                    Text("built in")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textMuted)
                }
                Spacer()
                if testing.contains(spec.id) {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Test") { test(spec) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textSidebarIcon)
                }
                if !ExternalAgentSpec.isPreset(spec.id) {
                    Button("Remove") {
                        results[spec.id] = nil
                        store.deleteExternalAgent(spec.id)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.orange)
                }
            }
            Text(spec.command.joined(separator: " "))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .textSelection(.enabled)
            if let note = ExternalAgentSetup.note(for: spec) {
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.orange)
            }
            if spec.id == "opencode" {
                Text(lmModels.isEmpty
                    ? "Models: opencode's own default. Load a model in LM Studio to pin it as lmstudio/<model>."
                    : "Models: opencode's default, or pin " + lmModels.map { LMStudioModels.openCodeValue($0) }.joined(separator: ", "))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textMuted)
            }
            if let result = results[spec.id] {
                Text(result.text)
                    .font(.system(size: 12))
                    .foregroundStyle(result.ok ? Theme.green : Theme.orange)
            }
        }
        .padding(.vertical, 8)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 0) {
            GrizzyField(label: "Name", placeholder: "My coding agent", text: $name)
            GrizzyField(
                label: "Command that starts it in ACP mode",
                placeholder: "opencode acp",
                text: $commandLine
            )
            .padding(.top, 8)
            Text("It runs on this Mac with your own sign-in. Test starts it and shakes hands without sending a prompt.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textMuted)
                .padding(.top, 6)
            if let problem {
                Text(problem)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.orange)
                    .padding(.top, 6)
            }
            HStack(spacing: 10) {
                GrizzyButton(
                    title: "Add agent",
                    variant: .cream,
                    size: .sm,
                    disabled: name.trimmingCharacters(in: .whitespaces).isEmpty
                        || commandLine.trimmingCharacters(in: .whitespaces).isEmpty
                ) {
                    if let message = store.addExternalAgent(name: name, commandLine: commandLine) {
                        problem = message
                    } else {
                        name = ""
                        commandLine = ""
                        problem = nil
                        adding = false
                    }
                }
                Button("Cancel") {
                    adding = false
                    problem = nil
                }
                .buttonStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
            }
            .padding(.top, 12)
        }
    }

    private func test(_ spec: ExternalAgentSpec) {
        testing.insert(spec.id)
        results[spec.id] = nil
        Task {
            let outcome = await AppStore.testExternalAgent(spec)
            results[spec.id] = TestResult(ok: outcome.ok, text: outcome.text)
            testing.remove(spec.id)
        }
    }
}
