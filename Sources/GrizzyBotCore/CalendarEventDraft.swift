import Foundation

/// One Google Calendar event assembled from the free-form `title`/`body` pair
/// that `plugin_call` hands every plugin write.
///
/// There is no structured event argument on the tool, so the body arrives as
/// JSON, as `key: value` lines, or as prose. All three are accepted. A body
/// with no usable start is not: guessing a date silently puts a wrong event on
/// someone's calendar, so `parse` throws and tells the caller what to send.
public struct CalendarEventDraft: Equatable, Sendable {
    public var calendarId: String
    public var summary: String
    public var details: String?
    public var location: String?
    public var isAllDay: Bool
    /// `yyyy-MM-dd` when all-day, otherwise RFC 3339.
    public var start: String
    /// Google treats an all-day `end.date` as exclusive, so a one-day event
    /// ends on the following day.
    public var end: String
    public var timeZone: String?
    public var recurrence: [String]

    public init(
        calendarId: String = "primary",
        summary: String,
        details: String? = nil,
        location: String? = nil,
        isAllDay: Bool,
        start: String,
        end: String,
        timeZone: String? = nil,
        recurrence: [String] = []
    ) {
        self.calendarId = calendarId
        self.summary = summary
        self.details = details
        self.location = location
        self.isAllDay = isAllDay
        self.start = start
        self.end = end
        self.timeZone = timeZone
        self.recurrence = recurrence
    }

    /// The request body for `POST /calendar/v3/calendars/{id}/events`.
    public func googleBody() -> [String: Any] {
        var out: [String: Any] = ["summary": summary]
        if isAllDay {
            out["start"] = ["date": start]
            out["end"] = ["date": end]
        } else {
            var startField: [String: Any] = ["dateTime": start]
            var endField: [String: Any] = ["dateTime": end]
            if let timeZone {
                startField["timeZone"] = timeZone
                endField["timeZone"] = timeZone
            }
            out["start"] = startField
            out["end"] = endField
        }
        if let details, !details.isEmpty { out["description"] = details }
        if let location, !location.isEmpty { out["location"] = location }
        if !recurrence.isEmpty { out["recurrence"] = recurrence }
        return out
    }

    public static let usage = """
        Send the event in the body as JSON, e.g. \
        {"start":"2026-10-05","all_day":true,"repeat":"monthly"} \
        or {"day":5,"repeat":"monthly"} for a day-of-month bill. \
        Timed events take {"start":"2026-10-05T09:00:00","end":"2026-10-05T10:00:00"}. \
        Optional: end, description, location, time_zone, recurrence (RRULE), calendar_id.
        """

    public static func parse(
        title: String,
        body: String,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) throws -> CalendarEventDraft {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        let fields = parseFields(body)
        let summary = firstNonEmpty(
            string(fields, "summary", "title", "name", "event"),
            title.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard let summary else {
            throw PluginError.rejected("A calendar event needs a title. \(usage)")
        }

        let explicitAllDay = bool(fields, "all_day", "allday", "isallday", "all-day")
        let rawStart = dateString(fields, "start", "start_date", "startdate", "date", "start_time", "starttime", "start_datetime")
        let rawEnd = dateString(fields, "end", "end_date", "enddate", "end_time", "endtime", "end_datetime")

        let dayOfMonth = integer(fields, "day", "day_of_month", "dayofmonth", "monthday", "bymonthday")
        let repeatWord = string(fields, "repeat", "repeats", "frequency", "freq", "recurs", "recurrence_frequency")
        let rawRecurrence = recurrenceStrings(fields)

        // Start: an explicit date wins; otherwise a day-of-month resolves to its
        // next occurrence, which is what "day 5 of every month" means.
        var start: String
        var isAllDay: Bool
        if let rawStart {
            start = rawStart
            isAllDay = explicitAllDay ?? !rawStart.contains("T")
        } else if let dayOfMonth {
            guard (1...31).contains(dayOfMonth) else {
                throw PluginError.rejected("day must be 1–31, got \(dayOfMonth).")
            }
            guard let date = nextOccurrence(ofDay: dayOfMonth, onOrAfter: now, calendar: calendar) else {
                throw PluginError.rejected("No upcoming date falls on day \(dayOfMonth).")
            }
            start = dateOnly(date, timeZone: timeZone)
            isAllDay = explicitAllDay ?? true
        } else {
            throw PluginError.rejected("Nothing was sent to Google — the event has no start. \(usage)")
        }

        if isAllDay, start.contains("T") {
            start = String(start.prefix(10))
        }

        // End: Google requires one. All-day ends are exclusive, so a single day
        // ends on the next date; a timed event defaults to an hour.
        let end: String
        if var rawEnd {
            if isAllDay {
                rawEnd = String(rawEnd.prefix(10))
                // An end equal to the start would be a zero-length event, which
                // Google rejects; callers who mean "one day" write either form.
                end = rawEnd == start ? try nextDay(after: start, calendar: calendar, timeZone: timeZone) : rawEnd
            } else {
                end = rawEnd
            }
        } else if isAllDay {
            end = try nextDay(after: start, calendar: calendar, timeZone: timeZone)
        } else {
            end = try plusOneHour(start, timeZone: timeZone)
        }

        var recurrence = try rawRecurrence.map { try normalizedRRule($0) }
        if recurrence.isEmpty, let repeatWord, let rule = frequencyRRule(repeatWord) {
            // "day 5, monthly" has to pin the month day, or Google repeats on
            // whatever day the first occurrence happened to land.
            let day = dayOfMonth ?? monthDay(of: start, calendar: calendar, timeZone: timeZone)
            recurrence = [rule.hasSuffix("MONTHLY") && day != nil ? "\(rule);BYMONTHDAY=\(day!)" : rule]
        }

        return CalendarEventDraft(
            calendarId: string(fields, "calendar_id", "calendarid", "calendar") ?? "primary",
            summary: summary,
            details: string(fields, "description", "details", "notes", "body"),
            location: string(fields, "location", "where"),
            isAllDay: isAllDay,
            start: start,
            end: end,
            timeZone: string(fields, "time_zone", "timezone", "tz") ?? (isAllDay ? nil : timeZone.identifier),
            recurrence: recurrence
        )
    }

    // MARK: - Body parsing

    /// JSON object, `key: value` lines, or prose (kept as the description).
    static func parseFields(_ body: String) -> [String: Any] {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }
        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object.reduce(into: [:]) { out, pair in
                out[normalizeKey(pair.key)] = pair.value
            }
        }
        var out: [String: Any] = [:]
        var unkeyed: [String] = []
        for line in trimmed.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard let separator = text.firstIndex(of: ":") else {
                if !text.isEmpty { unkeyed.append(text) }
                continue
            }
            let key = normalizeKey(String(text[text.startIndex..<separator]))
            let value = text[text.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            if key.isEmpty || value.isEmpty || key.contains(" ") {
                unkeyed.append(text)
            } else {
                out[key] = value
            }
        }
        if out.isEmpty {
            return ["description": trimmed]
        }
        if !unkeyed.isEmpty, out["description"] == nil {
            out["description"] = unkeyed.joined(separator: "\n")
        }
        return out
    }

    private static func normalizeKey(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespaces)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
    }

    private static func value(_ fields: [String: Any], _ keys: [String]) -> Any? {
        for key in keys {
            if let found = fields[normalizeKey(key)] { return found }
        }
        return nil
    }

    private static func string(_ fields: [String: Any], _ keys: String...) -> String? {
        guard let raw = value(fields, keys) else { return nil }
        let text: String
        switch raw {
        case let s as String: text = s
        case let n as NSNumber: text = n.stringValue
        default: return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Accepts both the flat form and Google's own `{"date": …}` / `{"dateTime": …}`.
    private static func dateString(_ fields: [String: Any], _ keys: String...) -> String? {
        guard let raw = value(fields, keys) else { return nil }
        if let nested = raw as? [String: Any] {
            for key in ["dateTime", "datetime", "date"] {
                if let text = nested[key] as? String, !text.isEmpty { return text }
            }
            return nil
        }
        guard let text = raw as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func bool(_ fields: [String: Any], _ keys: String...) -> Bool? {
        guard let raw = value(fields, keys) else { return nil }
        if let flag = raw as? Bool { return flag }
        if let number = raw as? NSNumber { return number.boolValue }
        guard let text = (raw as? String)?.lowercased() else { return nil }
        if ["true", "yes", "y", "1"].contains(text) { return true }
        if ["false", "no", "n", "0"].contains(text) { return false }
        return nil
    }

    private static func integer(_ fields: [String: Any], _ keys: String...) -> Int? {
        guard let raw = value(fields, keys) else { return nil }
        if let number = raw as? NSNumber { return number.intValue }
        guard let text = raw as? String else { return nil }
        return Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func recurrenceStrings(_ fields: [String: Any]) -> [String] {
        guard let raw = value(fields, ["recurrence", "rrule", "recurrence_rule"]) else { return [] }
        if let list = raw as? [Any] {
            return list.compactMap { $0 as? String }.filter { !$0.isEmpty }
        }
        if let text = raw as? String, !text.trimmingCharacters(in: .whitespaces).isEmpty {
            return [text]
        }
        return []
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        for value in values {
            if let value, !value.isEmpty { return value }
        }
        return nil
    }

    // MARK: - Recurrence

    /// A bare keyword becomes a rule; anything else must already be a real
    /// RRULE. A typo like `REQ=MONTHLY` is rejected rather than dropped —
    /// silently creating a one-off event is the worse failure.
    static func normalizedRRule(_ raw: String) throws -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        while text.hasPrefix("RRULE:") {
            text = String(text.dropFirst("RRULE:".count)).trimmingCharacters(in: .whitespaces)
        }
        guard !text.isEmpty else {
            throw PluginError.rejected("Empty recurrence rule.")
        }
        if let keyword = frequencyRRule(text) { return keyword }
        guard text.contains("FREQ=") else {
            throw PluginError.rejected(
                "\(raw) is not a recurrence rule — use a keyword (daily, weekly, monthly, yearly) or an RRULE like RRULE:FREQ=MONTHLY;BYMONTHDAY=5."
            )
        }
        return "RRULE:\(text)"
    }

    /// `monthly` → `RRULE:FREQ=MONTHLY`. Returns nil when the text is not a
    /// plain frequency keyword.
    static func frequencyRRule(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let word: String
        switch text {
        case "DAILY", "DAY", "EVERY DAY": word = "DAILY"
        case "WEEKLY", "WEEK", "EVERY WEEK": word = "WEEKLY"
        case "MONTHLY", "MONTH", "EVERY MONTH": word = "MONTHLY"
        case "YEARLY", "ANNUAL", "ANNUALLY", "YEAR", "EVERY YEAR": word = "YEARLY"
        case "NONE", "NEVER", "ONCE", "": return nil
        default: return nil
        }
        return "RRULE:FREQ=\(word)"
    }

    // MARK: - Dates

    static func nextOccurrence(ofDay day: Int, onOrAfter now: Date, calendar: Calendar) -> Date? {
        let today = calendar.startOfDay(for: now)
        var components = DateComponents()
        components.day = day
        components.hour = 0
        components.minute = 0
        components.second = 0
        // `.strict` skips months that have no such day (day 31 in February)
        // rather than rolling forward into the next month.
        return calendar.nextDate(
            after: today.addingTimeInterval(-1),
            matching: components,
            matchingPolicy: .strict,
            direction: .forward
        )
    }

    static func dateOnly(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func parseDateOnly(_ text: String, timeZone: TimeZone) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: String(text.prefix(10)))
    }

    static func nextDay(after start: String, calendar: Calendar, timeZone: TimeZone) throws -> String {
        guard let date = parseDateOnly(start, timeZone: timeZone),
              let next = calendar.date(byAdding: .day, value: 1, to: date)
        else {
            throw PluginError.rejected("\(start) is not a yyyy-MM-dd date.")
        }
        return dateOnly(next, timeZone: timeZone)
    }

    static func monthDay(of start: String, calendar: Calendar, timeZone: TimeZone) -> Int? {
        guard let date = parseDateOnly(start, timeZone: timeZone) else { return nil }
        return calendar.component(.day, from: date)
    }

    /// Default duration for a timed event whose caller gave no end.
    static func plusOneHour(_ start: String, timeZone: TimeZone) throws -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        for options in [
            ISO8601DateFormatter.Options([.withInternetDateTime]),
            ISO8601DateFormatter.Options([.withInternetDateTime, .withFractionalSeconds]),
        ] {
            formatter.formatOptions = options
            if let date = formatter.date(from: start) {
                formatter.formatOptions = [.withInternetDateTime]
                return formatter.string(from: date.addingTimeInterval(3600))
            }
        }
        // A local wall-clock time ("2026-10-05T09:00:00") carries no offset;
        // Google reads it against the event's timeZone, so shift it as text.
        let plain = DateFormatter()
        plain.calendar = Calendar(identifier: .gregorian)
        plain.locale = Locale(identifier: "en_US_POSIX")
        plain.timeZone = timeZone
        plain.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        guard let date = plain.date(from: start) else {
            throw PluginError.rejected("\(start) is not a date or date-time. \(usage)")
        }
        return plain.string(from: date.addingTimeInterval(3600))
    }
}
