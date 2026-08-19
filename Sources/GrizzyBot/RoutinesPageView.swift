import GrizzyBotCore
import SwiftUI

/// OpenMausBot-style routines calendar as a main shell view.
struct RoutinesPageView: View {
    @Environment(AppStore.self) private var store
    @State private var viewDays: Int = 7
    @State private var anchor = Calendar.current.startOfDay(for: Date())
    @State private var botFilter = "all"
    @State private var selectedRoutine: Routine?

    private var rangeStart: Date {
        if viewDays == 7 {
            return startOfWeek(anchor)
        }
        return Calendar.current.startOfDay(for: anchor)
    }

    private var dayColumns: [Date] {
        (0..<viewDays).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: rangeStart) }
    }

    private var filteredRoutines: [Routine] {
        store.allRoutines.filter { botFilter == "all" || $0.botId == botFilter }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if filteredRoutines.isEmpty {
                emptyState
            } else {
                calendar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bgMain)
        .sheet(item: $selectedRoutine) { routine in
            RoutineDetailsSheet(routine: routine)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        Text("◷")
                            .foregroundStyle(Theme.orange)
                        Text("Routines")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(Theme.textBright)
                    }
                    Text("Scheduled work for your bots while GrizzyBot is open.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                if store.missedRoutineCount > 0 {
                    Text("\(store.missedRoutineCount) need attention")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.orange)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Theme.orange.opacity(0.12))
                        .clipShape(Capsule())
                }
                Button {
                    store.showChat()
                    if store.activeBotId == nil {
                        store.activeBotId = store.visibleBots.first?.id
                    }
                    store.openNewRoutine()
                } label: {
                    Text("+ New routine")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textCream)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Theme.bgCream)
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(store.visibleBots.isEmpty)
                .opacity(store.visibleBots.isEmpty ? 0.4 : 1)
            }

            HStack(spacing: 8) {
                HStack(spacing: 0) {
                    navButton("‹") { move(-1) }
                    Button("Today") { goToday() }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textBright)
                        .buttonStyle(.plain)
                        .padding(.horizontal, 10)
                    navButton("›") { move(1) }
                }
                .padding(3)
                .background(Theme.bgCard)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Theme.borderListRowsAlt, lineWidth: 1)
                }

                Text(monthTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textBright)
                    .padding(.leading, 6)

                Menu {
                    Button("All bots") { botFilter = "all" }
                    ForEach(store.visibleBots) { bot in
                        Button(bot.name) { botFilter = bot.id }
                    }
                } label: {
                    Text(botFilter == "all" ? "All bots" : (store.bots.first(where: { $0.id == botFilter })?.name ?? "Bot"))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textBright)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Theme.bgCard)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Theme.borderListRowsAlt, lineWidth: 1)
                        }
                }
                .menuStyle(.borderlessButton)

                Spacer()

                HStack(spacing: 2) {
                    ForEach([1, 3, 7], id: \.self) { days in
                        Button {
                            viewDays = days
                            if days == 7 { anchor = startOfWeek(anchor) }
                            else { anchor = Calendar.current.startOfDay(for: anchor) }
                        } label: {
                            Text(days == 1 ? "Day" : days == 3 ? "3 days" : "Week")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(viewDays == days ? Theme.textBright : Theme.textSecondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(viewDays == days ? Theme.bgHoverRow : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(3)
                .background(Theme.bgCard)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Text("Put your bots on a rhythm")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.textBright)
            Text("Plan research briefs, daily check-ins, or recurring reviews. Each run becomes a chat turn with a result.")
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button {
                store.showChat()
                store.openNewRoutine()
            } label: {
                Text("Create your first routine")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textCream)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Theme.bgCream)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(store.visibleBots.isEmpty)
            if store.visibleBots.isEmpty {
                Text("Create a bot first, then come back to schedule it.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.orange)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var calendar: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 8) {
                ForEach(dayColumns, id: \.self) { day in
                    dayColumn(day)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .grizzyScroll()
    }

    private func dayColumn(_ day: Date) -> some View {
        let items = filteredRoutines.filter { routine in
            guard let next = routine.nextRunAt else { return false }
            return Calendar.current.isDate(next, inSameDayAs: day)
        }
        return VStack(alignment: .leading, spacing: 8) {
            Text(dayHeader(day))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Calendar.current.isDateInToday(day) ? Theme.orange : Theme.textSecondary)
                .padding(.horizontal, 4)

            ForEach(items) { routine in
                Button {
                    selectedRoutine = routine
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(routine.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.textBright)
                            .lineLimit(2)
                        Text(botName(routine.botId))
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textSecondary)
                        Text(Cron.formatCron(routine.cron))
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textMuted)
                        if !routine.active {
                            Text("paused")
                                .font(.system(size: 10.5))
                                .foregroundStyle(Theme.orange)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.bgCard)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Theme.borderListRowsAlt, lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Edit") {
                        store.selectBot(routine.botId)
                        store.openRoutine(routine)
                    }
                    Button("Run now") {
                        store.runRoutine(routine.id)
                    }
                    Button(routine.active ? "Pause" : "Resume") {
                        store.setRoutineActive(routine.id, active: !routine.active)
                    }
                    Button("Delete", role: .destructive) {
                        store.deleteRoutine(routine.id)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(8)
        .frame(minHeight: 320, alignment: .top)
        .background(Theme.bgSidebar.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func navButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
    }

    private var monthTitle: String {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f.string(from: rangeStart)
    }

    private func dayHeader(_ day: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE d"
        return f.string(from: day)
    }

    private func botName(_ id: String) -> String {
        store.bots.first(where: { $0.id == id })?.name ?? "Bot"
    }

    private func move(_ direction: Int) {
        if let next = Calendar.current.date(byAdding: .day, value: direction * viewDays, to: anchor) {
            anchor = next
        }
    }

    private func goToday() {
        let today = Date()
        anchor = viewDays == 7 ? startOfWeek(today) : Calendar.current.startOfDay(for: today)
    }

    private func startOfWeek(_ date: Date) -> Date {
        var cal = Calendar.current
        cal.firstWeekday = 2
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return cal.date(from: comps) ?? Calendar.current.startOfDay(for: date)
    }
}

/// OpenMausBot-style routine details: Edit / Run now / Pause / Delete.
private struct RoutineDetailsSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let routine: Routine

    private var live: Routine {
        store.allRoutines.first(where: { $0.id == routine.id }) ?? routine
    }

    private var botName: String {
        store.bots.first(where: { $0.id == live.botId })?.name ?? "Bot"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(live.name)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Theme.textBright)
                    Text("\(botName) · \(Cron.formatCron(live.cron))")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Text("✕")
                        .foregroundStyle(Theme.textMuted)
                }
                .buttonStyle(.plain)
            }
            .padding(20)

            VStack(alignment: .leading, spacing: 12) {
                Text("Instructions")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
                ScrollView {
                    Text(live.prompt)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textBright)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .textSelection(.enabled)
                }
                .grizzyScroll()
                .frame(maxWidth: .infinity, minHeight: 80, maxHeight: 140, alignment: .topLeading)
                .padding(12)
                .background(Theme.bgCard)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                Text("Assigned bot")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
                Menu {
                    ForEach(store.visibleBots) { bot in
                        Button(bot.name) {
                            store.assignRoutine(live.id, toBotId: bot.id)
                        }
                    }
                } label: {
                    HStack {
                        Text(botName)
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.textBright)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.textMuted)
                    }
                    .padding(12)
                    .background(Theme.bgCard)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .menuStyle(.borderlessButton)

                if !live.active {
                    Text("Paused — will not create new runs.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.orange)
                }
            }
            .padding(.horizontal, 20)

            Spacer(minLength: 16)

            HStack(spacing: 8) {
                Button {
                    store.runRoutine(live.id)
                    dismiss()
                } label: {
                    Text("Run now")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textCream)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Theme.bgCream)
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    store.selectBot(live.botId)
                    store.openRoutine(live)
                    dismiss()
                } label: {
                    Text("Edit")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textBright)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .overlay {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .stroke(Theme.borderInputsDark, lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)

                Button {
                    store.setRoutineActive(live.id, active: !live.active)
                } label: {
                    Text(live.active ? "Pause" : "Resume")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    store.deleteRoutine(live.id)
                    dismiss()
                } label: {
                    Text("Delete")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.orange)
                }
                .buttonStyle(.plain)
            }
            .padding(20)
        }
        .frame(width: 480, height: 360)
        .background(Theme.bgRightPanel)
    }
}
