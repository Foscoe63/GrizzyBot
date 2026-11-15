import SwiftUI
import GrizzyBotCore

/// A department's shared notes. Bots propose facts; here the person accepts, edits, pins or deletes them.
/// Only accepted notes reach a bot's prompt, and the dialog says how many fit.
struct DepartmentMemorySheet: View {
    @Environment(AppStore.self) private var store
    let department: String
    let onClose: () -> Void

    @State private var editing: DepartmentFact?
    @State private var formOpen = false
    @State private var kind: DepartmentFactKind = .term
    @State private var name = ""
    @State private var detail = ""
    @State private var aliases = ""
    @State private var error = ""

    private var label: String { department.isEmpty ? "General" : department }
    private var facts: [DepartmentFact] { store.departmentFacts(department) }
    private var proposed: [DepartmentFact] { facts.filter { $0.status == .proposed } }
    private var accepted: [DepartmentFact] { facts.filter { $0.status == .accepted } }
    private var selection: DepartmentMemory.Selection { store.departmentMemorySelection(department) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "brain").foregroundStyle(Theme.orange)
                Text("\(label) shared memory").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.textBright)
                Spacer()
                Button { openForm(nil) } label: { Label("Add a note", systemImage: "plus").font(.system(size: 12, weight: .medium)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.textBright)
            }
            Text("People, places, decisions and terms every bot in this department shares. Bots suggest notes; nothing is shared until you accept it. Private notes stay in each bot's own memory.")
                .font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)

            if !formOpen, !error.isEmpty {
                Text(error).font(.system(size: 12)).foregroundStyle(Theme.orange)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if formOpen { form }
                    if !proposed.isEmpty {
                        sectionTitle("To review (\(proposed.count))")
                        ForEach(proposed) { card($0) }
                    }
                    sectionTitle("Shared notes (\(accepted.count))")
                    if accepted.isEmpty {
                        Text("No shared notes yet. Add one, or accept a suggestion from a bot.")
                            .font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                    }
                    ForEach(accepted) { card($0) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 260, maxHeight: 420)

            HStack {
                Text(selection.total == 0 ? "" : "\(selection.loadedIds.count) of \(selection.total) notes fit in each bot's prompt (6,000 bytes); the rest stay searchable by the bots.")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
                Spacer()
                GrizzyButton(title: "Done", variant: .cream, size: .sm, action: onClose).keyboardShortcut(.cancelAction)
            }
        }
        .padding(24).frame(width: 640).background(Theme.bgRightPanel)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textSecondary)
    }

    private func card(_ fact: DepartmentFact) -> some View {
        let isProposal = fact.status == .proposed
        let loaded = selection.loadedIds.contains(fact.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(fact.kind.label).font(.system(size: 10.5, weight: .medium))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Theme.bgChip)).foregroundStyle(Theme.textSecondary)
                Text(fact.name).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.textBright)
                if fact.pinned { Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(Theme.orange) }
                Spacer()
                if !isProposal && !loaded { Text("not in prompt").font(.system(size: 10.5)).foregroundStyle(Theme.textMuted) }
            }
            if !fact.detail.isEmpty {
                Text(fact.detail).font(.system(size: 12.5)).foregroundStyle(Theme.textBright).fixedSize(horizontal: false, vertical: true)
            }
            if !fact.aliases.isEmpty {
                Text("Also: " + fact.aliases.joined(separator: ", ")).font(.system(size: 11.5)).foregroundStyle(Theme.textMuted)
            }
            if isProposal {
                let who = fact.sourceName.isEmpty ? "a bot" : fact.sourceName
                Text("Suggested by \(who), \(fact.proposedAt.formatted(date: .abbreviated, time: .shortened))" + (fact.replaces.isEmpty ? "" : ". Would replace the note with the same key."))
                    .font(.system(size: 11.5)).foregroundStyle(Theme.textMuted)
            }
            HStack(spacing: 14) {
                if isProposal {
                    GrizzyButton(title: "Accept", variant: .cream, size: .sm) { run { try store.resolveDepartmentFact(department, id: fact.id, accept: true, expectedRevision: fact.revision) } }
                    Button("Edit") { openForm(fact) }
                    Button("Reject") { run { try store.resolveDepartmentFact(department, id: fact.id, accept: false, expectedRevision: fact.revision) } }
                } else {
                    Button("Edit") { openForm(fact) }
                    Button(fact.pinned ? "Unpin" : "Pin") { run { try store.updateDepartmentFact(department, id: fact.id, patch: .init(pinned: !fact.pinned), expectedRevision: fact.revision) } }
                    Button("Delete", role: .destructive) { run { try store.removeDepartmentFact(department, id: fact.id, expectedRevision: fact.revision) } }
                }
            }
            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(isProposal ? Theme.orange.opacity(0.08) : Theme.bgCard))
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(editing == nil ? "New note" : (editing?.status == .proposed ? "Edit and accept" : "Edit note"))
            Picker("Kind", selection: $kind) { ForEach(DepartmentFactKind.allCases) { Text($0.label).tag($0) } }
                .pickerStyle(.segmented).labelsHidden()
            TextField("Name (\(DepartmentMemory.nameMax) characters at most)", text: $name).textFieldStyle(.roundedBorder)
            TextField("Detail: the fact, its context, why it matters", text: $detail, axis: .vertical)
                .lineLimit(3...6).textFieldStyle(.roundedBorder)
            TextField("Also known as (comma separated)", text: $aliases).textFieldStyle(.roundedBorder)
            HStack {
                Text("\(detail.count) / \(DepartmentMemory.detailMax)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(detail.count > DepartmentMemory.detailMax ? Theme.orange : Theme.textMuted)
                if !error.isEmpty { Text(error).font(.system(size: 11.5)).foregroundStyle(Theme.orange) }
                Spacer()
                Button("Cancel") { closeForm() }.buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
                GrizzyButton(title: editing?.status == .proposed ? "Save and accept" : "Save", variant: .cream, size: .sm,
                             disabled: name.trimmingCharacters(in: .whitespaces).isEmpty || detail.count > DepartmentMemory.detailMax, action: saveForm)
            }
        }
        .padding(12).background(RoundedRectangle(cornerRadius: 10).fill(Theme.bgHoverRow))
    }

    private func openForm(_ fact: DepartmentFact?) {
        editing = fact
        kind = fact?.kind ?? .term
        name = fact?.name ?? ""
        detail = fact?.detail ?? ""
        aliases = fact?.aliases.joined(separator: ", ") ?? ""
        error = ""
        formOpen = true
    }

    private func closeForm() { formOpen = false; editing = nil; error = "" }

    private func saveForm() {
        let list = aliases.split(separator: ",").map { String($0) }
        let current = editing
        run {
            if let current {
                try store.updateDepartmentFact(department, id: current.id,
                    patch: .init(kind: kind, name: name, detail: detail, aliases: list), expectedRevision: current.revision)
            } else {
                try store.addDepartmentFact(department, DepartmentFactInput(kind: kind, name: name, detail: detail, aliases: list))
            }
            closeForm()
        }
    }

    /// Runs a change and shows why it was refused (stale, duplicate, too long) instead of failing silently.
    private func run(_ change: () throws -> Void) {
        do { try change(); if !formOpen { error = "" } } catch { self.error = error.localizedDescription }
    }
}
