import GrizzyBotCore
import SwiftUI

struct SkillsOverlayView: View {
    @Environment(AppStore.self) private var store
    @State private var search = ""
    @State private var creating = false
    /// Non-nil while the form is editing an existing skill rather than making one.
    @State private var editingId: String?
    @State private var draftId = ""
    @State private var draftDescription = ""
    @State private var draftBody = ""
    @State private var error: String?

    private var filtered: [AgentSkill] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return store.skills }
        return store.skills.filter {
            $0.id.contains(q) || $0.name.lowercased().contains(q) || $0.description.lowercased().contains(q)
        }
    }

    var body: some View {
        ZStack {
            Color(red: 4 / 255, green: 4 / 255, blue: 5 / 255).opacity(0.62)
                .ignoresSafeArea()
                .onTapGesture { store.skillsOpen = false }

            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Skills")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(Theme.textBrightAlt)
                        Text("\(store.skills.count) packaged workflows · load with read_skill")
                            .font(.system(size: 13.5))
                            .foregroundStyle(Theme.textPluginsSub)
                    }
                    Spacer()
                    Button {
                        if creating { resetDraft() } else { creating = true }
                    } label: {
                        Text(creating ? "Cancel" : "New skill")
                            .font(.system(size: 13.5))
                            .foregroundStyle(Theme.textGhost)
                    }
                    .buttonStyle(.plain)
                    Button {
                        store.skillsOpen = false
                    } label: {
                        Text("✕")
                            .font(.system(size: 16))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 12)
                }
                .padding(.horizontal, 32)
                .padding(.top, 28)

                if creating {
                    createForm
                        .padding(.horizontal, 32)
                        .padding(.top, 16)
                } else {
                    TextField("Search skills", text: $search)
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textBright)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(Color(hex: "#101012"))
                        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .stroke(Theme.borderInputsDark, lineWidth: 1)
                        }
                        .padding(.horizontal, 32)
                        .padding(.top, 16)
                }

                if let error {
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.redError)
                        .padding(.horizontal, 32)
                        .padding(.top, 10)
                }

                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(filtered) { skill in
                            skillRow(skill)
                        }
                    }
                    .padding(.horizontal, 32)
                    .padding(.vertical, 24)
                }
                .grizzyScroll()
                .frame(maxHeight: .infinity)
            }
            .frame(width: 720, height: 640)
            .background(Theme.bgPluginsCard)
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .accessibilityIdentifier(OverlayA11y.skills)
            .overlay {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(Theme.borderListRowsAlt, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.55), radius: 40, y: 16)
        }
        .accessibilityIdentifier(OverlayA11y.skills)
        .accessibilityElement(children: .contain)
    }

    private var createForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let editingId {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Id")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                    Text(editingId)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.textBright)
                }
            } else {
                GrizzyField(label: "Id", placeholder: "my-workflow", text: $draftId)
            }
            GrizzyField(label: "Description", placeholder: "When to use this skill", text: $draftDescription)
            GrizzyField(
                label: "Body",
                placeholder: "Markdown instructions the agent follows after read_skill",
                text: $draftBody,
                axis: .vertical,
                lineLimit: 6...12
            )
            HStack(spacing: 10) {
                GrizzyButton(title: editingId == nil ? "Save skill" : "Save changes", variant: .cream, size: .sm) {
                    saveDraft()
                }
                .disabled(draftId.trimmingCharacters(in: .whitespaces).isEmpty
                    || draftDescription.trimmingCharacters(in: .whitespaces).isEmpty)
                addActionMenu
                Spacer()
            }
            if editingBundled {
                Text("Saving keeps the bundled skill's id and overrides it with your copy.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textMuted)
            }
        }
    }

    /// Ready-made interaction steps. A TextEditor exposes no caret, so a chosen
    /// action lands at the end of the body rather than at the cursor.
    private var addActionMenu: some View {
        Menu {
            ForEach(SkillActions.all) { action in
                Button {
                    draftBody = SkillActions.append(action, to: draftBody)
                } label: {
                    Text("\(action.label) — \(action.summary)")
                }
            }
        } label: {
            Text("Add action ▾")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textGhost)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Theme.bgDarkButtonAlt)
                .clipShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var editingBundled: Bool {
        guard let editingId else { return false }
        return store.skills.first(where: { $0.id == editingId })?.source == .bundled
    }

    private func skillRow(_ skill: AgentSkill) -> some View {
        let enabled = store.activeBot?.enabledSkills.contains(skill.id) ?? true
        return HStack(alignment: .top, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.bgPluginLogo)
                    .frame(width: 42, height: 42)
                Text(String(skill.id.prefix(1)).uppercased())
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textBright)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(skill.id)
                        .font(.system(size: 15.5, weight: .medium))
                        .foregroundStyle(Theme.textBright)
                    Text(skill.source == .bundled ? "bundled" : "user")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textMuted)
                }
                Text(skill.description)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.textPluginsSub)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Open in editor") {
                store.openSkillInEditor(skill.id)
            }
            .buttonStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(Theme.textGhost)
            Button("Edit") {
                beginEdit(skill)
            }
            .buttonStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(Theme.textGhost)
            if skill.source == .user {
                Button("Delete") {
                    try? store.deleteUserSkill(skill.id)
                }
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Theme.orange)
            }
            if let bot = store.activeBot {
                Button {
                    store.setBotSkill(bot.id, skillId: skill.id, enabled: !enabled)
                } label: {
                    Text(enabled ? "On" : "Off")
                        .font(.system(size: 13))
                        .foregroundStyle(enabled ? Theme.green : Theme.textGhost)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Theme.bgDarkButtonAlt)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func beginEdit(_ skill: AgentSkill) {
        error = nil
        editingId = skill.id
        draftId = skill.id
        draftDescription = skill.description
        draftBody = skill.body
        creating = true
    }

    private func resetDraft() {
        creating = false
        editingId = nil
        draftId = ""
        draftDescription = ""
        draftBody = ""
        error = nil
    }

    private func saveDraft() {
        error = nil
        do {
            // installUserSkill writes by slugged id, so an edit overwrites the
            // same SKILL.md instead of leaving a second copy behind.
            try store.installUserSkill(
                id: editingId ?? draftId,
                description: draftDescription,
                body: draftBody
            )
            resetDraft()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
