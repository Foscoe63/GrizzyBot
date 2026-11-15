import SwiftUI
import GrizzyBotCore

/// Edits one department's shared instructions: the text every bot in it sees at the start of each turn.
/// Mirrors OpenMausBot's dialog: a byte counter that turns red past the limit, a last-saved time,
/// Save only when something changed and it fits, and a discard prompt if you close with unsaved edits.
struct DepartmentInstructionsSheet: View {
    @Environment(AppStore.self) private var store
    let department: String
    let onClose: () -> Void

    @State private var text = ""
    @State private var savedText = ""
    @State private var updatedAt: Date?
    @State private var error = ""
    @State private var confirmDiscard = false
    @State private var loaded = false

    private var label: String { department.isEmpty ? "General" : department }
    private var bytes: Int { DepartmentInstructions.byteCount(text) }
    private var overLimit: Bool { bytes > DepartmentInstructions.maxBytes }
    private var dirty: Bool { text != savedText }
    private var memberCount: Int { store.teamMapSections.first(where: { $0.key == department })?.count ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "book").foregroundStyle(Theme.orange)
                Text("\(label) shared instructions").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.textBright)
            }
            Text("Shared instructions shown to every bot in this department at the start of each turn. Only you can edit them; bots cannot.")
                .font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            GrizzyTextEditor(
                placeholder: "Goals\n- Ship the onboarding refresh\n\nDecisions\n- Keep customer data local\n\nPreferences\n- Use concise weekly updates",
                text: $text, fontSize: 12.5, textColor: Theme.textBright, lines: 12...14
            )
            .accessibilityLabel("\(label) shared instructions")
            HStack(alignment: .top) {
                Text(footnote).font(.system(size: 11.5)).foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Text("\(bytes.formatted()) / \(DepartmentInstructions.maxBytes.formatted()) bytes")
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(overLimit ? Theme.orange : Theme.textMuted)
            }
            if !error.isEmpty {
                Text(error).font(.system(size: 12)).foregroundStyle(Theme.orange)
            }
            HStack {
                Spacer()
                Button("Cancel") { close() }
                    .buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
                    .keyboardShortcut(.cancelAction)
                GrizzyButton(title: "Save shared instructions", variant: .cream, size: .sm, disabled: !dirty || overLimit) { save() }
            }
        }
        .padding(24).frame(width: 600).background(Theme.bgRightPanel)
        .onAppear(perform: load)
        .interactiveDismissDisabled(dirty)
        .confirmationDialog("Discard unsaved changes to these shared instructions?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard changes", role: .destructive) { onClose() }
            Button("Keep editing", role: .cancel) {}
        }
    }

    private var footnote: String {
        var parts = ["Keep durable department facts here. Private notes stay in each bot's own Memory."]
        if let updatedAt { parts.append("Last saved \(updatedAt.formatted(date: .abbreviated, time: .shortened)).") }
        return parts.joined(separator: " ")
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        let brief = store.departmentInstructions(department)
        text = brief?.text ?? ""
        savedText = text
        updatedAt = brief?.updatedAt
    }

    private func close() {
        if dirty { confirmDiscard = true } else { onClose() }
    }

    private func save() {
        switch store.setDepartmentInstructions(department, text: text) {
        case .saved, .cleared:
            let brief = store.departmentInstructions(department)
            savedText = text
            updatedAt = brief?.updatedAt
            error = ""
            onClose()
        case .tooLong(let size, let limit):
            error = "That is \(size.formatted()) bytes; the limit is \(limit.formatted())."
        case .unknownDepartment:
            error = "This department no longer exists."
        }
    }
}
