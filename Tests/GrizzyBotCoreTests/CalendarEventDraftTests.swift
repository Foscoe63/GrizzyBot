import Foundation
import Testing
@testable import GrizzyBotCore

private let utc = TimeZone(identifier: "UTC")!

private func on(_ text: String) -> Date {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = utc
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.date(from: text)!
}

@Suite("Calendar event drafts")
struct CalendarEventDraftTests {
    @Test("A day-of-month bill becomes a monthly all-day event on its next occurrence")
    func dayOfMonthMonthly() throws {
        let draft = try CalendarEventDraft.parse(
            title: "Blue Ridge Electric",
            body: #"{"day":5,"repeat":"monthly"}"#,
            now: on("2026-09-12"),
            timeZone: utc
        )
        #expect(draft.summary == "Blue Ridge Electric")
        #expect(draft.isAllDay)
        #expect(draft.start == "2026-10-05")
        // All-day ends are exclusive, so one day ends on the next date.
        #expect(draft.end == "2026-10-06")
        #expect(draft.recurrence == ["RRULE:FREQ=MONTHLY;BYMONTHDAY=5"])
        #expect(draft.calendarId == "primary")
    }

    @Test("A day that has not passed yet this month starts this month")
    func dayOfMonthThisMonth() throws {
        let draft = try CalendarEventDraft.parse(
            title: "Skyline Internet",
            body: #"{"day":20,"repeat":"monthly"}"#,
            now: on("2026-09-12"),
            timeZone: utc
        )
        #expect(draft.start == "2026-09-20")
    }

    @Test("Today counts as the next occurrence")
    func dayOfMonthToday() throws {
        let draft = try CalendarEventDraft.parse(
            title: "Verizon Wireless",
            body: #"{"day":12,"repeat":"monthly"}"#,
            now: on("2026-09-12"),
            timeZone: utc
        )
        #expect(draft.start == "2026-09-12")
    }

    @Test("The Google body carries date fields for all-day events")
    func allDayGoogleBody() throws {
        let draft = try CalendarEventDraft.parse(
            title: "BCBS Insurance",
            body: #"{"day":28,"repeat":"monthly"}"#,
            now: on("2026-09-12"),
            timeZone: utc
        )
        let json = draft.googleBody()
        #expect(json["summary"] as? String == "BCBS Insurance")
        #expect((json["start"] as? [String: Any])?["date"] as? String == "2026-09-28")
        #expect((json["end"] as? [String: Any])?["date"] as? String == "2026-09-29")
        #expect((json["start"] as? [String: Any])?["dateTime"] == nil)
        #expect(json["recurrence"] as? [String] == ["RRULE:FREQ=MONTHLY;BYMONTHDAY=28"])
    }

    @Test("A timed event defaults to an hour and keeps its time zone")
    func timedDefaultsToAnHour() throws {
        let draft = try CalendarEventDraft.parse(
            title: "Portfolio Review",
            body: #"{"start":"2026-10-05T09:00:00"}"#,
            now: on("2026-09-12"),
            timeZone: utc
        )
        #expect(!draft.isAllDay)
        #expect(draft.end == "2026-10-05T10:00:00")
        let json = draft.googleBody()
        #expect((json["start"] as? [String: Any])?["dateTime"] as? String == "2026-10-05T09:00:00")
        #expect((json["end"] as? [String: Any])?["timeZone"] as? String == utc.identifier)
    }

    @Test("Google's own nested start/end shape is accepted")
    func nestedGoogleShape() throws {
        let draft = try CalendarEventDraft.parse(
            title: "Cedar Key Water",
            body: #"{"start":{"date":"2026-09-27"},"end":{"date":"2026-09-28"},"allDay":true}"#,
            now: on("2026-09-12"),
            timeZone: utc
        )
        #expect(draft.start == "2026-09-27")
        #expect(draft.end == "2026-09-28")
    }

    @Test("An all-day end equal to the start is widened to a real day")
    func zeroLengthAllDayIsWidened() throws {
        let draft = try CalendarEventDraft.parse(
            title: "Spectrum Internet",
            body: #"{"start":"2026-09-25","end":"2026-09-25","all_day":true}"#,
            now: on("2026-09-12"),
            timeZone: utc
        )
        #expect(draft.end == "2026-09-26")
    }

    @Test("key: value lines parse like JSON")
    func keyValueLines() throws {
        let draft = try CalendarEventDraft.parse(
            title: "Cedar Key Electric",
            body: "day: 10\nrepeat: monthly\nlocation: Cedar Key",
            now: on("2026-09-12"),
            timeZone: utc
        )
        #expect(draft.start == "2026-10-10")
        #expect(draft.location == "Cedar Key")
        #expect(draft.recurrence == ["RRULE:FREQ=MONTHLY;BYMONTHDAY=10"])
    }

    @Test("An explicit start with a monthly repeat pins the month day")
    func explicitStartPinsMonthDay() throws {
        let draft = try CalendarEventDraft.parse(
            title: "Progressive Insurance",
            body: #"{"start":"2026-10-08","repeat":"monthly"}"#,
            now: on("2026-09-12"),
            timeZone: utc
        )
        #expect(draft.recurrence == ["RRULE:FREQ=MONTHLY;BYMONTHDAY=8"])
    }

    @Test("A full RRULE passes through, with or without the prefix")
    func rruleRoundTrip() throws {
        #expect(try CalendarEventDraft.normalizedRRule("FREQ=WEEKLY;BYDAY=MO") == "RRULE:FREQ=WEEKLY;BYDAY=MO")
        #expect(try CalendarEventDraft.normalizedRRule("RRULE:FREQ=MONTHLY") == "RRULE:FREQ=MONTHLY")
        #expect(try CalendarEventDraft.normalizedRRule("monthly") == "RRULE:FREQ=MONTHLY")
    }

    @Test("A mistyped rule is rejected rather than silently dropped")
    func mistypedRuleThrows() {
        #expect(throws: PluginError.self) {
            _ = try CalendarEventDraft.normalizedRRule("REQ=MONTHLY")
        }
    }

    @Test("A body with no start is refused instead of guessing a date")
    func missingStartThrows() {
        #expect(throws: PluginError.self) {
            _ = try CalendarEventDraft.parse(
                title: "Blue Ridge Electric",
                body: "pay the electric bill",
                now: on("2026-09-12"),
                timeZone: utc
            )
        }
    }

    @Test("An untitled event is refused")
    func missingTitleThrows() {
        #expect(throws: PluginError.self) {
            _ = try CalendarEventDraft.parse(
                title: "",
                body: #"{"day":5,"repeat":"monthly"}"#,
                now: on("2026-09-12"),
                timeZone: utc
            )
        }
    }

    @Test("Day 31 skips months that have no such day")
    func day31SkipsShortMonths() throws {
        let draft = try CalendarEventDraft.parse(
            title: "Rent",
            body: #"{"day":31,"repeat":"monthly"}"#,
            now: on("2026-02-01"),
            timeZone: utc
        )
        #expect(draft.start == "2026-03-31")
    }
}
