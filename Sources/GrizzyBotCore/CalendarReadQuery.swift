import Foundation

/// A parsed Google Calendar read.
///
/// The tool takes one free-form string, so "what is on today" and "find the
/// Verizon bill" arrive the same way. They are not the same request: one is a
/// time window, the other is a text search. Sending both to Google's `q=`
/// parameter — which only ever does full-text matching — is why a perfectly
/// healthy calendar reported "No Calendar events for primary".
public struct CalendarReadQuery: Sendable, Equatable {
    public var calendarId: String
    /// Full-text search term, or nil to list by time instead.
    public var text: String?
    public var timeMin: Date?
    public var timeMax: Date?
    public var maxResults: Int
    /// How the caller described this read, for the "nothing found" message.
    public var describedAs: String

    public init(
        calendarId: String = "primary",
        text: String? = nil,
        timeMin: Date? = nil,
        timeMax: Date? = nil,
        maxResults: Int = 25,
        describedAs: String = ""
    ) {
        self.calendarId = calendarId
        self.text = text
        self.timeMin = timeMin
        self.timeMax = timeMax
        self.maxResults = maxResults
        self.describedAs = describedAs
    }

    /// Words that mean "just show me the calendar" rather than a search term.
    /// `primary` is here because `normalizedReadQuery` substitutes it for an
    /// empty query — searching for the literal word was the original bug.
    static let placeholders: Set<String> = [
        "", "primary", "list", "get", "read", "search", "all", "any",
        "upcoming", "events", "calendar", "my calendar", "agenda", "schedule",
    ]

    public func url() -> String {
        var parts = [
            "maxResults=\(maxResults)",
            "singleEvents=true",
            "orderBy=startTime",
        ]
        if let text, !text.isEmpty {
            parts.append("q=\(Self.escape(text))")
        }
        if let timeMin {
            parts.append("timeMin=\(Self.escape(Self.rfc3339(timeMin)))")
        }
        if let timeMax {
            parts.append("timeMax=\(Self.escape(Self.rfc3339(timeMax)))")
        }
        let id = Self.escape(calendarId)
        return "https://www.googleapis.com/calendar/v3/calendars/\(id)/events?" + parts.joined(separator: "&")
    }

    static func escape(_ raw: String) -> String {
        raw.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? raw
    }

    static func rfc3339(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}

public enum CalendarReadQueryParser {
    /// Default window for "what's coming up" when no dates are given.
    public static let defaultWindowDays = 30

    public static func parse(
        _ raw: String,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> CalendarReadQuery {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let fields = structuredFields(trimmed)

        var query = CalendarReadQuery(describedAs: trimmed.isEmpty ? "this calendar" : trimmed)
        if let id = fields["calendarid"] ?? fields["calendar_id"] ?? fields["calendar"], !id.isEmpty {
            query.calendarId = id
        }
        if let count = (fields["maxresults"] ?? fields["max_results"] ?? fields["limit"]).flatMap(Int.init) {
            query.maxResults = min(100, max(1, count))
        }

        // Structured time bounds win over anything inferred from prose.
        let rawMin = fields["timemin"] ?? fields["time_min"] ?? fields["start"] ?? fields["from"] ?? fields["after"]
        let rawMax = fields["timemax"] ?? fields["time_max"] ?? fields["end"] ?? fields["to"] ?? fields["before"]
        if let rawMin, let date = date(from: rawMin, calendar: calendar) {
            query.timeMin = date
        }
        if let rawMax, let date = date(from: rawMax, calendar: calendar) {
            // A bare date as an upper bound means "through the end of that day".
            query.timeMax = rawMax.count <= 10 ? endOfDay(date, calendar: calendar) : date
        }

        let term = fields["q"] ?? fields["query"] ?? fields["text"] ?? fields["search"]
            ?? (fields.isEmpty ? trimmed : nil)

        if let term, !CalendarReadQuery.placeholders.contains(term.lowercased()) {
            if let window = window(for: term, now: now, calendar: calendar) {
                query.timeMin = query.timeMin ?? window.start
                query.timeMax = query.timeMax ?? window.end
            } else {
                query.text = term
            }
        }

        // No text and no bounds means "show me the calendar": upcoming from today.
        if query.text == nil, query.timeMin == nil, query.timeMax == nil {
            query.timeMin = calendar.startOfDay(for: now)
            query.timeMax = calendar.date(byAdding: .day, value: defaultWindowDays, to: calendar.startOfDay(for: now))
        }
        return query
    }

    /// A date, a range, or a relative phrase — anything that describes *when*
    /// rather than *what*.
    static func window(
        for raw: String,
        now: Date,
        calendar: Calendar
    ) -> (start: Date, end: Date)? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let today = calendar.startOfDay(for: now)

        func days(_ offset: Int, _ span: Int = 1) -> (Date, Date)? {
            guard let start = calendar.date(byAdding: .day, value: offset, to: today),
                  let end = calendar.date(byAdding: .day, value: span, to: start)
            else { return nil }
            return (start, end)
        }

        switch text {
        case "today": return days(0)
        case "tomorrow": return days(1)
        case "yesterday": return days(-1)
        case "this week", "week": return days(0, 7)
        case "next week": return days(7, 7)
        case "this month", "month": return days(0, 31)
        default: break
        }

        // "2026-09-01..2026-09-30" or "2026-09-01 to 2026-09-30"
        for separator in ["..", " to ", "…", " - "] where text.contains(separator) {
            let halves = text.components(separatedBy: separator)
            if halves.count == 2,
               let start = dateOnly(halves[0].trimmingCharacters(in: .whitespaces), calendar: calendar),
               let end = dateOnly(halves[1].trimmingCharacters(in: .whitespaces), calendar: calendar) {
                return (start, endOfDay(end, calendar: calendar))
            }
        }

        if let day = dateOnly(text, calendar: calendar) {
            return (day, endOfDay(day, calendar: calendar))
        }
        return nil
    }

    static func date(from raw: String, calendar: Calendar) -> Date? {
        if let day = dateOnly(raw, calendar: calendar) { return day }
        let formatter = ISO8601DateFormatter()
        for options in [
            ISO8601DateFormatter.Options([.withInternetDateTime]),
            ISO8601DateFormatter.Options([.withInternetDateTime, .withFractionalSeconds]),
        ] {
            formatter.formatOptions = options
            if let date = formatter.date(from: raw) { return date }
        }
        let plain = DateFormatter()
        plain.calendar = Calendar(identifier: .gregorian)
        plain.locale = Locale(identifier: "en_US_POSIX")
        plain.timeZone = calendar.timeZone
        plain.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return plain.date(from: raw)
    }

    static func dateOnly(_ raw: String, calendar: Calendar) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count == 10 else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text)
    }

    static func endOfDay(_ date: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) ?? date
    }

    /// JSON object or `key: value` / `key=value` lines. Plain prose yields none.
    static func structuredFields(_ raw: String) -> [String: String] {
        guard !raw.isEmpty else { return [:] }
        if let data = raw.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var out: [String: String] = [:]
            for (key, value) in object {
                let normalized = key.lowercased().replacingOccurrences(of: "-", with: "_")
                switch value {
                case let text as String: out[normalized] = text
                case let number as NSNumber: out[normalized] = number.stringValue
                default: continue
                }
                out[normalized.replacingOccurrences(of: "_", with: "")] = out[normalized]
            }
            return out
        }
        var out: [String: String] = [:]
        for line in raw.split(whereSeparator: { $0 == "\n" || $0 == "&" }) {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard let separator = text.firstIndex(where: { $0 == ":" || $0 == "=" }) else { continue }
            let key = text[text.startIndex..<separator]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
                .replacingOccurrences(of: "-", with: "_")
            let value = text[text.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            // A bare "2026-09-12" has a colon-free shape; a date-time does not,
            // so only accept keys that look like identifiers.
            guard !key.isEmpty, !value.isEmpty, key.allSatisfy({ $0.isLetter || $0 == "_" }) else { continue }
            out[key] = value
            out[key.replacingOccurrences(of: "_", with: "")] = value
        }
        return out
    }
}
