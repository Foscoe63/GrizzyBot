import Foundation
import Testing
@testable import GrizzyBotCore

private let utc = TimeZone(identifier: "UTC")!

private func on(_ text: String) -> Date {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = utc
    f.dateFormat = "yyyy-MM-dd"
    return f.date(from: text)!
}

private func parse(_ raw: String, now: String = "2026-09-12") -> CalendarReadQuery {
    CalendarReadQueryParser.parse(raw, now: on(now), timeZone: utc)
}

@Suite("Calendar reads")
struct CalendarReadQueryTests {
    @Test("The placeholder query lists upcoming events instead of searching for the word")
    func placeholderListsUpcoming() {
        // This is the exact bug: normalizedReadQuery substitutes "primary" for
        // an empty query, and it used to be sent as a full-text search term.
        for placeholder in ["", "primary", "list", "upcoming", "my calendar"] {
            let q = parse(placeholder)
            #expect(q.text == nil, "\(placeholder) was treated as a search term")
            #expect(q.timeMin == on("2026-09-12"), "\(placeholder) has no start bound")
            #expect(q.timeMax != nil)
            #expect(!q.url().contains("q="), "\(placeholder) still sends q=")
            #expect(q.url().contains("timeMin="))
        }
    }

    @Test("A bare date reads that whole day")
    func singleDate() {
        let q = parse("2026-09-12")
        #expect(q.text == nil)
        #expect(q.timeMin == on("2026-09-12"))
        #expect(q.timeMax == on("2026-09-13"))
    }

    @Test("A date range reads the range, end inclusive")
    func dateRange() {
        for raw in ["2026-09-01..2026-09-30", "2026-09-01 to 2026-09-30"] {
            let q = parse(raw)
            #expect(q.text == nil, "\(raw) was treated as a search")
            #expect(q.timeMin == on("2026-09-01"))
            #expect(q.timeMax == on("2026-10-01"), "\(raw) should include the last day")
        }
    }

    @Test("Relative phrases resolve against today")
    func relativePhrases() {
        #expect(parse("today").timeMin == on("2026-09-12"))
        #expect(parse("today").timeMax == on("2026-09-13"))
        #expect(parse("tomorrow").timeMin == on("2026-09-13"))
        #expect(parse("yesterday").timeMin == on("2026-09-11"))
        #expect(parse("this week").timeMax == on("2026-09-19"))
    }

    @Test("Real text is still a text search, with no time bounds")
    func textStillSearches() {
        let q = parse("Verizon Wireless")
        #expect(q.text == "Verizon Wireless")
        #expect(q.timeMin == nil)
        #expect(q.timeMax == nil)
        #expect(q.url().contains("q=Verizon%20Wireless") || q.url().contains("q=Verizon%2520Wireless") || q.url().contains("Verizon"))
    }

    @Test("A JSON query is understood, including calendar and bounds")
    func jsonQuery() {
        let q = parse(#"{"calendarId":"work@example.com","timeMin":"2026-09-01","timeMax":"2026-09-30","maxResults":5}"#)
        #expect(q.calendarId == "work@example.com")
        #expect(q.timeMin == on("2026-09-01"))
        #expect(q.timeMax == on("2026-10-01"))
        #expect(q.maxResults == 5)
        #expect(q.text == nil)
    }

    @Test("A JSON text search keeps searching")
    func jsonTextQuery() {
        let q = parse(#"{"q":"Blue Ridge Electric"}"#)
        #expect(q.text == "Blue Ridge Electric")
        #expect(q.timeMin == nil)
    }

    @Test("key: value lines work too")
    func keyValueQuery() {
        let q = parse("calendar_id: team@example.com\nstart: 2026-10-01\nend: 2026-10-07")
        #expect(q.calendarId == "team@example.com")
        #expect(q.timeMin == on("2026-10-01"))
        #expect(q.timeMax == on("2026-10-08"))
    }

    @Test("A named calendar is carried through rather than searched for")
    func namedCalendar() {
        let q = parse(#"{"calendarId":"Ed Griswold"}"#)
        #expect(q.calendarId == "Ed Griswold")
        #expect(q.text == nil, "the calendar name must not become a search term")
    }

    @Test("The URL is well formed and always ordered")
    func urlShape() {
        let url = parse("2026-09-12").url()
        #expect(url.hasPrefix("https://www.googleapis.com/calendar/v3/calendars/primary/events?"))
        #expect(url.contains("singleEvents=true"))
        #expect(url.contains("orderBy=startTime"))
        #expect(url.contains("timeMin=2026-09-12T00%3A00%3A00Z"))
    }

    @Test("A calendar id with an @ is escaped into the path")
    func calendarIdEscaped() {
        let url = parse(#"{"calendarId":"work@example.com"}"#).url()
        #expect(url.contains("calendars/work%40example.com/events"))
    }

    @Test("maxResults is clamped to something Google accepts")
    func maxResultsClamped() {
        #expect(parse(#"{"maxResults":9999}"#).maxResults == 100)
        #expect(parse(#"{"maxResults":0}"#).maxResults == 1)
        #expect(parse("today").maxResults == 25)
    }
}
