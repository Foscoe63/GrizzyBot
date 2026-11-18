import SwiftUI
import GrizzyBotCore

/// Chief of Staff setting: which other departments it is in charge of. In its own department (and any ticked
/// here) it may stop and delete bots it did not create. It can still message any bot. Only the person edits this.
struct ChiefDepartmentsSettings: View {
    @Environment(AppStore.self) private var store
    let botId: String

    private var chief: Bot? { store.bots.first(where: { $0.id == botId }) }

    var body: some View {
        if let chief {
            let own = store.department(of: botId)
            let others = store.allDepartmentKeys.filter { $0 != own }
            VStack(alignment: .leading, spacing: 6) {
                Text("Also in charge of")
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.textBright)
                Text("This bot answers for its own department (\(own.isEmpty ? "General" : own)). Tick more and it may also stop or delete bots in them, even ones it did not create. It can message any bot either way. A new department is added automatically while it is in charge of every department.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                if others.isEmpty {
                    Text("There are no other departments yet.").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
                ForEach(others, id: \.self) { key in
                    Toggle(key.isEmpty ? "General" : key, isOn: Binding(
                        get: { chief.managedDepartments.contains(key) },
                        set: { on in
                            var next = chief.managedDepartments.filter { $0 != key }
                            if on { next.append(key) }
                            store.setManagedDepartments(botId, next)
                        }
                    ))
                    .font(.system(size: 12.5))
                }
            }
            .padding(.top, 10)
        }
    }
}
