import GrizzyBotCore
import SwiftUI

struct RoutineScheduleView: View {
    @Binding var preset: Cron.Preset

    private var description: (lead: String, detail: String) {
        Cron.describe(preset)
    }

    private var numberOptions: [Int] {
        var opts = Cron.numbers
        if !opts.contains(preset.n) {
            opts.append(preset.n)
            opts.sort()
        }
        return opts
    }

    private var timeOptions: [String] {
        var opts = Cron.times
        if !opts.contains(preset.time), !preset.time.isEmpty {
            opts.append(preset.time)
        }
        return opts
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ClockIcon()
                    .stroke(Theme.textGhost, style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                    .frame(width: 17, height: 17)
                Text(description.lead)
                    .font(.system(size: 14.5))
                    .foregroundStyle(Theme.textBright)
                if !description.detail.isEmpty {
                    Text(description.detail)
                        .font(.system(size: 14.5))
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            FlowRow(spacing: 8) {
                chipSelect(
                    options: Cron.freqs,
                    selection: Binding(
                        get: { preset.freq },
                        set: { newFreq in
                            var next = preset
                            if newFreq == "Advanced" {
                                next.cron = Cron.fromPreset(preset)
                            }
                            next.freq = newFreq
                            preset = next
                        }
                    )
                )

                if preset.freq == "Interval" {
                    Text("every")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textSidebarIcon)
                    chipSelect(
                        options: numberOptions.map(String.init),
                        selection: Binding(
                            get: { String(preset.n) },
                            set: { preset.n = Int($0) ?? preset.n }
                        )
                    )
                    chipSelect(
                        options: Cron.units,
                        selection: Binding(
                            get: { preset.unit },
                            set: { preset.unit = $0 }
                        )
                    )
                }

                if ["Every day", "Weekdays", "Every week", "Every month"].contains(preset.freq) {
                    Text("at")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textSidebarIcon)
                    chipSelect(
                        options: timeOptions,
                        selection: Binding(
                            get: { preset.time },
                            set: { preset.time = $0 }
                        )
                    )
                }

                if preset.freq == "Advanced" {
                    TextField("*/3 * * * *", text: Binding(
                        get: { preset.cron },
                        set: { preset.cron = $0 }
                    ))
                    .font(.system(size: 13.5, design: .monospaced))
                    .foregroundStyle(Theme.textBright)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Theme.bgChip)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .frame(minWidth: 140)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .background(Theme.bgScheduleInner)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .padding(.top, 10)
        }
        .padding(12)
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(Theme.borderInputsDark, lineWidth: 1)
        }
    }

    private func chipSelect(options: [String], selection: Binding<String>) -> some View {
        GrizzySelect(options: options, selection: selection, style: .chip)
    }
}

private struct ClockIcon: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = min(rect.width, rect.height) / 2
        let c = CGPoint(x: rect.midX, y: rect.midY)
        path.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        path.move(to: c)
        path.addLine(to: CGPoint(x: c.x, y: c.y - r * 0.55))
        path.move(to: c)
        path.addLine(to: CGPoint(x: c.x + r * 0.4, y: c.y))
        return path
    }
}

/// Simple wrapping HStack for schedule chips.
private struct FlowRow<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: () -> Content

    var body: some View {
        // Use LazyVGrid with adaptive columns for wrap-like behavior.
        let cols = [GridItem(.adaptive(minimum: 72), spacing: spacing, alignment: .leading)]
        LazyVGrid(columns: cols, alignment: .leading, spacing: spacing) {
            content()
        }
    }
}
