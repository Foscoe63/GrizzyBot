import SwiftUI
import GrizzyBotCore

/// A team note a bot proposed, in the chat where it proposed it. The person can accept or reject it right
/// here, and take an accept back while the note is untouched. The state is read live, so the same note
/// accepted in the department's memory dialog shows up here too.
struct TeamNoteCard: View {
    @Environment(AppStore.self) private var store
    let department: String
    let factId: String

    @State private var error = ""

    private var label: String { department.isEmpty ? "General" : department }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let fact = store.departmentFact(department, id: factId) {
                header(fact)
                if !fact.detail.isEmpty {
                    Text(fact.detail).font(.system(size: 13)).foregroundStyle(Theme.textBright)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !fact.aliases.isEmpty {
                    Text("Also: " + fact.aliases.joined(separator: ", ")).font(.system(size: 11.5)).foregroundStyle(Theme.textMuted)
                }
                actions(fact)
                if !error.isEmpty { Text(error).font(.system(size: 12)).foregroundStyle(Theme.orange) }
            } else {
                Text("This team note is no longer available.").font(.system(size: 12.5)).foregroundStyle(Theme.textMuted)
            }
        }
        .padding(14)
        .frame(maxWidth: 460, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.bgCard))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.orange.opacity(0.25)))
    }

    private func header(_ fact: DepartmentFact) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "brain").foregroundStyle(Theme.orange)
            Text(fact.kind.label).font(.system(size: 10.5, weight: .medium))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Theme.bgChip)).foregroundStyle(Theme.textSecondary)
            Text(fact.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textBright)
            Spacer()
            Text(status(fact)).font(.system(size: 11.5)).foregroundStyle(Theme.textMuted)
        }
    }

    private func status(_ fact: DepartmentFact) -> String {
        switch fact.status {
        case .proposed: return "Suggested for \(label) shared memory"
        case .accepted: return "In \(label) shared memory"
        case .superseded: return "Replaced by a newer note"
        case .deleted: return fact.updatedAt > fact.proposedAt && fact.acceptedRevision == nil ? "Rejected" : "Removed"
        }
    }

    @ViewBuilder
    private func actions(_ fact: DepartmentFact) -> some View {
        switch fact.status {
        case .proposed:
            HStack(spacing: 12) {
                GrizzyButton(title: "Accept", variant: .cream, size: .sm) {
                    run { try store.resolveDepartmentFact(department, id: fact.id, accept: true, expectedRevision: fact.revision) }
                }
                Button("Reject") {
                    run { try store.resolveDepartmentFact(department, id: fact.id, accept: false, expectedRevision: fact.revision) }
                }
                .buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
                if !fact.replaces.isEmpty {
                    Text("Replaces the note with the same key.").font(.system(size: 11.5)).foregroundStyle(Theme.textMuted)
                }
            }
        case .accepted where DepartmentMemory.canUndo(fact):
            Button("Undo") { run { try store.undoDepartmentFactAccept(department, id: fact.id) } }
                .buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
        default:
            EmptyView()
        }
    }

    /// Runs a change and shows why it was refused (stale, conflicting) instead of failing silently.
    private func run(_ change: () throws -> Void) {
        do { try change(); error = "" } catch { self.error = error.localizedDescription }
    }
}
