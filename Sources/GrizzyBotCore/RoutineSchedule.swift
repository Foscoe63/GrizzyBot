import Foundation

/// Turns what a model says about a schedule into a cron expression GrizzyBot can actually run, and
/// refuses what it can't. `Cron.nextDate` quietly treats a bad expression as "a minute from now", which
/// is the wrong failure for a routine nobody is watching.
public enum RoutineSchedule {
    public struct Checked: Equatable, Sendable {
        public var cron: String
        public var description: String
        /// Shortest gap between two consecutive runs, in minutes.
        public var minGapMinutes: Int
    }

    public enum Problem: Error, Equatable, LocalizedError {
        case missing
        case malformed(String)
        case tooFrequent(Int)

        public var errorDescription: String? {
            switch self {
            case .missing:
                return "Give a schedule: either cron (five fields, e.g. \"0 9 * * 1,3,5\") or days (e.g. \"mon,wed,fri\") with a time (e.g. \"9:00\")."
            case .malformed(let why):
                return "That schedule isn't valid: \(why)"
            case .tooFrequent(let minutes):
                return "That would run every \(minutes) minute\(minutes == 1 ? "" : "s"). Routines a bot creates must be at least \(RoutineSchedule.minimumGapMinutes) minutes apart."
            }
        }
    }

    /// Fastest a bot may schedule on its own.
    public static let minimumGapMinutes = 15

    private static let dayNumbers: [String: Int] = [
        "sun": 0, "sunday": 0, "mon": 1, "monday": 1, "tue": 2, "tues": 2, "tuesday": 2, "wed": 3, "wednesday": 3,
        "thu": 4, "thur": 4, "thurs": 4, "thursday": 4, "fri": 5, "friday": 5, "sat": 6, "saturday": 6,
    ]

    /// `days` is "mon,wed,fri", "weekdays", "weekends", "daily", or a range like "mon-fri".
    public static func cron(days: String, time: String) -> String? {
        let clock = time.trimmingCharacters(in: .whitespaces).lowercased()
        guard clock.first?.isNumber == true else { return nil }
        let pm = clock.contains("pm"), am = clock.contains("am")
        let pieces = clock.split(separator: ":", maxSplits: 1).map(String.init)
        guard var hour = Int(pieces[0].filter(\.isNumber)) else { return nil }
        let minute = pieces.count > 1 ? (Int(pieces[1].filter(\.isNumber).prefix(2)) ?? -1) : 0
        guard (0...59).contains(minute) else { return nil }
        if am || pm {
            guard (1...12).contains(hour) else { return nil }
            if pm, hour < 12 { hour += 12 }
            if am, hour == 12 { hour = 0 }
        }
        guard (0...23).contains(hour) else { return nil }

        let text = days.lowercased().trimmingCharacters(in: .whitespaces)
        let field: String
        switch text {
        case "", "daily", "every day", "everyday", "*": field = "*"
        case "weekdays", "weekday": field = "1-5"
        case "weekends", "weekend": field = "0,6"
        default:
            if text.contains("-"), !text.contains(",") {
                let ends = text.split(separator: "-").map { dayNumbers[String($0).trimmingCharacters(in: .whitespaces)] }
                guard ends.count == 2, let a = ends[0], let b = ends[1], a <= b else { return nil }
                field = "\(a)-\(b)"
            } else {
                let numbers = text.split(separator: ",").map { dayNumbers[String($0).trimmingCharacters(in: .whitespaces)] }
                guard !numbers.isEmpty, !numbers.contains(where: { $0 == nil }) else { return nil }
                field = Array(Set(numbers.compactMap { $0 })).sorted().map(String.init).joined(separator: ",")
            }
        }
        return "\(minute) \(hour) * * \(field)"
    }

    /// Checks every field against the forms `Cron` evaluates, then measures how often it fires.
    public static func validate(cron raw: String, now: Date = .now) throws -> Checked {
        let cron = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cron.isEmpty else { throw Problem.missing }
        let fields = cron.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard fields.count == 5 else {
            throw Problem.malformed("cron needs five fields — minute hour day-of-month month day-of-week.")
        }
        let limits: [(String, ClosedRange<Int>)] = [
            ("minute", 0...59), ("hour", 0...23), ("day of month", 1...31), ("month", 1...12), ("day of week", 0...7),
        ]
        for (field, (name, range)) in zip(fields, limits) {
            try check(field, name: name, range: range)
        }
        let gap = minimumGap(cron, from: now)
        guard gap >= minimumGapMinutes else { throw Problem.tooFrequent(gap) }
        return Checked(cron: cron, description: Cron.formatCron(cron), minGapMinutes: gap)
    }

    private static func check(_ field: String, name: String, range: ClosedRange<Int>) throws {
        func fail() -> Problem { .malformed("“\(field)” is not a valid \(name) (allowed \(range.lowerBound)–\(range.upperBound)).") }
        if field == "*" { return }
        if field.hasPrefix("*/") {
            guard let step = Int(field.dropFirst(2)), step > 0, step <= range.upperBound else { throw fail() }
            return
        }
        if field.contains(",") {
            let items = field.split(separator: ",", omittingEmptySubsequences: false).map { Int($0) }
            guard !items.contains(where: { $0 == nil }), items.allSatisfy({ range.contains($0!) }) else { throw fail() }
            return
        }
        if field.contains("-") {
            let ends = field.split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
            guard ends.count == 2, let a = ends[0], let b = ends[1], range.contains(a), range.contains(b), a <= b else { throw fail() }
            return
        }
        guard let value = Int(field), range.contains(value) else { throw fail() }
    }

    static func minimumGap(_ cron: String, from now: Date, samples: Int = 40) -> Int {
        var previous = Cron.nextDate(cron, from: now)
        var smallest = Int.max
        for _ in 0..<samples {
            let next = Cron.nextDate(cron, from: previous)
            guard next > previous, next != .distantFuture else { break }
            smallest = min(smallest, Int(next.timeIntervalSince(previous) / 60))
            previous = next
        }
        return smallest == Int.max ? Int.max / 2 : smallest
    }

    /// From the tool's arguments: `cron`, or `days` plus `time`.
    public static func resolve(cron: String, days: String, time: String, now: Date = .now) throws -> Checked {
        if !cron.trimmingCharacters(in: .whitespaces).isEmpty { return try validate(cron: cron, now: now) }
        guard !time.trimmingCharacters(in: .whitespaces).isEmpty else { throw Problem.missing }
        guard let built = Self.cron(days: days, time: time) else {
            throw Problem.malformed("couldn't read days “\(days)” and time “\(time)”. Use days like \"mon,wed,fri\" or \"weekdays\" and a time like \"9:00\" or \"6:30 PM\".")
        }
        return try validate(cron: built, now: now)
    }
}
