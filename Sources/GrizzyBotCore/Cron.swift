import Foundation

/// Port of rakazo's `packages/core/src/cron.ts` — everyday-language cron presets.
public enum Cron {
    public static let freqs: [String] = [
        "Every hour",
        "Every day",
        "Weekdays",
        "Every week",
        "Every month",
        "Interval",
        "Advanced",
    ]

    public static let units: [String] = ["minutes", "hours", "days"]
    public static let numbers: [Int] = [1, 2, 3, 5, 10, 15, 30, 45]
    public static let times: [String] = [
        "6:00 AM",
        "7:00 AM",
        "8:00 AM",
        "9:00 AM",
        "12:00 PM",
        "3:00 PM",
        "6:00 PM",
        "9:00 PM",
    ]

    static let weekdays = "1-5"

    public struct Preset: Codable, Sendable, Hashable {
        public var freq: String
        public var n: Int
        public var unit: String
        public var time: String
        public var cron: String

        public init(freq: String, n: Int, unit: String, time: String, cron: String) {
            self.freq = freq
            self.n = n
            self.unit = unit
            self.time = time
            self.cron = cron
        }
    }

    public static func defaultPreset() -> Preset {
        Preset(freq: "Every day", n: 3, unit: "minutes", time: "9:00 AM", cron: "")
    }

    public static func fromPreset(_ input: Preset) -> String {
        if input.freq == "Advanced" {
            let trimmed = input.cron.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? "*/3 * * * *" : trimmed
        }
        if input.freq == "Every hour" { return "0 * * * *" }
        if input.freq == "Interval" {
            let n = input.n > 0 ? input.n : 5
            if input.unit == "days" { return "0 0 */\(n) * *" }
            if input.unit == "hours" { return "0 */\(n) * * *" }
            return "*/\(n) * * * *"
        }
        let clock = parseClock(input.time.isEmpty ? "9:00 AM" : input.time)
        if input.freq == "Weekdays" { return "\(clock.minute) \(clock.hour) * * \(weekdays)" }
        if input.freq == "Every week" { return "\(clock.minute) \(clock.hour) * * 1" }
        if input.freq == "Every month" { return "\(clock.minute) \(clock.hour) 1 * *" }
        return "\(clock.minute) \(clock.hour) * * *"
    }

    public static func preset(fromCron cron: String) -> Preset {
        let base = defaultPreset()
        let trimmed = cron.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        if parts.count < 5 {
            return Preset(freq: "Advanced", n: base.n, unit: base.unit, time: base.time, cron: trimmed)
        }
        let minute = parts[0]
        let hour = parts[1]
        let day = parts[2]
        let month = parts[3]
        let dow = parts[4]
        if month != "*" {
            return Preset(freq: "Advanced", n: base.n, unit: base.unit, time: base.time, cron: trimmed)
        }

        let minuteStep = stepValue(minute)
        let hourStep = stepValue(hour)
        let dayStep = stepValue(day)

        if minute == "0" && hour == "*" && day == "*" && dow == "*" {
            return Preset(freq: "Every hour", n: base.n, unit: base.unit, time: base.time, cron: "")
        }
        if let minuteStep, hour == "*", day == "*", dow == "*" {
            return Preset(freq: "Interval", n: minuteStep, unit: "minutes", time: base.time, cron: "")
        }
        if minute == "0", let hourStep, day == "*", dow == "*" {
            return Preset(freq: "Interval", n: hourStep, unit: "hours", time: base.time, cron: "")
        }
        if minute == "0" && hour == "0", let dayStep, dow == "*" {
            return Preset(freq: "Interval", n: dayStep, unit: "days", time: base.time, cron: "")
        }
        guard isInt(minute), isInt(hour) else {
            return Preset(freq: "Advanced", n: base.n, unit: base.unit, time: base.time, cron: trimmed)
        }

        let time = formatClock(hour: Int(hour) ?? 0, minute: Int(minute) ?? 0)
        if day == "*" && dow == weekdays {
            return Preset(freq: "Weekdays", n: base.n, unit: base.unit, time: time, cron: "")
        }
        if day == "*" && dow == "1" {
            return Preset(freq: "Every week", n: base.n, unit: base.unit, time: time, cron: "")
        }
        if day == "1" && dow == "*" {
            return Preset(freq: "Every month", n: base.n, unit: base.unit, time: time, cron: "")
        }
        if day == "*" && dow == "*" {
            return Preset(freq: "Every day", n: base.n, unit: base.unit, time: time, cron: "")
        }
        return Preset(freq: "Advanced", n: base.n, unit: base.unit, time: base.time, cron: trimmed)
    }

    public static func describe(_ preset: Preset) -> (lead: String, detail: String) {
        switch preset.freq {
        case "Interval":
            return ("Every", "\(preset.n) \(preset.unit)")
        case "Every hour":
            return ("Every hour", "")
        case "Advanced":
            return ("Cron", preset.cron.isEmpty ? "*/3 * * * *" : preset.cron)
        case "Weekdays":
            return ("Weekdays", "at \(preset.time)")
        case "Every week":
            return ("Every Monday", "at \(preset.time)")
        case "Every month":
            return ("Monthly", "on the 1st at \(preset.time)")
        default:
            return ("Every day", "at \(preset.time)")
        }
    }

    public static func formatSchedule(_ preset: Preset) -> String {
        let d = describe(preset)
        return [d.lead, d.detail].filter { !$0.isEmpty }.joined(separator: " ")
    }

    public static func formatCron(_ cron: String) -> String {
        formatSchedule(preset(fromCron: cron))
    }

    // MARK: - Helpers (mirroring the TS implementation)

    static func parseClock(_ time: String) -> (hour: Int, minute: Int) {
        let pieces = time.split(separator: ":", maxSplits: 1).map(String.init)
        let rawH = pieces.first ?? "9"
        let rest = pieces.count > 1 ? pieces[1] : "00"
        var minute = Int(rest.prefix(2)) ?? 0
        if minute > 59 { minute = 0 }
        var hour = Int(rawH) ?? 9
        if time.range(of: "pm", options: .caseInsensitive) != nil && hour < 12 { hour += 12 }
        if time.range(of: "am", options: .caseInsensitive) != nil && hour == 12 { hour = 0 }
        return (hour, minute)
    }

    static func formatClock(hour: Int, minute: Int) -> String {
        let period = hour >= 12 ? "PM" : "AM"
        let h12 = hour % 12 == 0 ? 12 : hour % 12
        return String(format: "%d:%02d %@", h12, minute, period)
    }

    static func stepValue(_ expr: String) -> Int? {
        guard expr.hasPrefix("*/") else { return nil }
        let n = Int(expr.dropFirst(2))
        guard let n, n > 0 else { return nil }
        return n
    }

    static func isInt(_ expr: String) -> Bool {
        !expr.isEmpty && expr.allSatisfy { $0.isNumber }
    }

    /// Next minute (UTC) matching the cron expression, mirroring `nextCronDate`.
    public static func nextDate(_ cron: String, from: Date) -> Date {
        let parts = cron.trimmingCharacters(in: .whitespaces).split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard parts.count >= 5 else { return from.addingTimeInterval(60) }
        let minuteExpr = parts[0]
        let hourExpr = parts[1]
        let candidate = from.addingTimeInterval(60)
        let calendar = Calendar(identifier: .gregorian)
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: candidate)
        components.second = 0
        guard var date = calendar.date(from: components) else { return from.addingTimeInterval(60) }
        for _ in 0..<(24 * 60 + 2) {
            let c = calendar.dateComponents([.hour, .minute], from: date)
            if matchField(minuteExpr, c.minute ?? 0, min: 0, max: 59)
                && matchField(hourExpr, c.hour ?? 0, min: 0, max: 23) {
                return date
            }
            date = calendar.date(byAdding: .minute, value: 1, to: date) ?? date.addingTimeInterval(60)
        }
        return from.addingTimeInterval(60)
    }

    static func matchField(_ expr: String, _ value: Int, min: Int, max: Int) -> Bool {
        if expr == "*" { return true }
        if expr.hasPrefix("*/") {
            let step = Int(expr.dropFirst(2)) ?? 0
            return step > 0 && value % step == 0
        }
        if expr.contains("-") {
            let bounds = expr.split(separator: "-").compactMap { Int($0) }
            let a = bounds.first ?? min
            let b = bounds.count > 1 ? bounds[1] : max
            return value >= a && value <= b
        }
        if expr.contains(",") {
            return expr.split(separator: ",").compactMap { Int($0) }.contains(value)
        }
        return Int(expr) == value
    }
}
