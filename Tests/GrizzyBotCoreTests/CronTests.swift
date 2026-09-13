import Foundation
import GrizzyBotCore
import Testing

@Suite("Cron")
struct CronTests {
    private func preset(
        freq: String,
        n: Int = 3,
        unit: String = "minutes",
        time: String = "9:00 AM",
        cron: String = ""
    ) -> Cron.Preset {
        Cron.Preset(freq: freq, n: n, unit: unit, time: time, cron: cron)
    }

    @Test("maps everyday language onto cron")
    func everydayLanguage() {
        #expect(Cron.fromPreset(preset(freq: "Every day", time: "9:00 AM")) == "0 9 * * *")
        #expect(Cron.fromPreset(preset(freq: "Weekdays", time: "8:00 AM")) == "0 8 * * 1-5")
        #expect(Cron.fromPreset(preset(freq: "Every week", time: "9:00 AM")) == "0 9 * * 1")
        #expect(Cron.fromPreset(preset(freq: "Every month", time: "12:00 PM")) == "0 12 1 * *")
        #expect(Cron.fromPreset(preset(freq: "Every hour")) == "0 * * * *")
        #expect(Cron.fromPreset(preset(freq: "Every day", time: "12:00 AM")) == "0 0 * * *")
        #expect(Cron.fromPreset(preset(freq: "Every day", time: "3:00 PM")) == "0 15 * * *")
    }

    @Test("maps intervals including days")
    func intervals() {
        #expect(Cron.fromPreset(preset(freq: "Interval", n: 15, unit: "minutes")) == "*/15 * * * *")
        #expect(Cron.fromPreset(preset(freq: "Interval", n: 2, unit: "hours")) == "0 */2 * * *")
        #expect(Cron.fromPreset(preset(freq: "Interval", n: 3, unit: "days")) == "0 0 */3 * *")
    }

    @Test("keeps advanced expressions")
    func advanced() {
        #expect(Cron.fromPreset(preset(freq: "Advanced", cron: "0 10 15 * *")) == "0 10 15 * *")
        #expect(Cron.fromPreset(preset(freq: "Advanced", cron: "")) == "*/3 * * * *")
    }

    @Test("reads Monday-morning default as weekly")
    func weeklyFromCron() {
        let parsed = Cron.preset(fromCron: "0 9 * * 1")
        #expect(parsed.freq == "Every week")
        #expect(parsed.time == "9:00 AM")
    }

    @Test("round-trips named presets")
    func roundTrip() {
        let cases: [Cron.Preset] = [
            preset(freq: "Every hour"),
            preset(freq: "Every day", time: "6:00 PM"),
            preset(freq: "Weekdays", time: "7:00 AM"),
            preset(freq: "Every week", time: "9:00 AM"),
            preset(freq: "Every month", time: "12:00 PM"),
            preset(freq: "Interval", n: 10, unit: "minutes"),
            preset(freq: "Interval", n: 5, unit: "hours"),
            preset(freq: "Interval", n: 2, unit: "days"),
            preset(freq: "Advanced", cron: "0 10 15 * *"),
        ]
        for input in cases {
            let cron = Cron.fromPreset(input)
            let parsed = Cron.preset(fromCron: cron)
            #expect(parsed.freq == input.freq)
            if input.freq == "Interval" {
                #expect(parsed.n == input.n)
                #expect(parsed.unit == input.unit)
            }
            if ["Every day", "Weekdays", "Every week", "Every month"].contains(input.freq) {
                #expect(parsed.time == input.time)
            }
            if input.freq == "Advanced" {
                #expect(parsed.cron == input.cron)
            }
        }
    }

    @Test("falls back to advanced for unrepresentable expressions")
    func advancedFallback() {
        #expect(Cron.preset(fromCron: "0 9 * * 0").freq == "Advanced")
        #expect(Cron.preset(fromCron: "0 9 * * 0").cron == "0 9 * * 0")
        #expect(Cron.preset(fromCron: "30 14 15 * *").freq == "Advanced")
        #expect(Cron.preset(fromCron: "30 14 15 * *").cron == "30 14 15 * *")
    }

    @Test("formatCron and describe")
    func formatAndDescribe() {
        #expect(Cron.formatCron("*/15 * * * *") == "Every 15 minutes")
        let described = Cron.describe(preset(freq: "Every hour"))
        #expect(described.lead == "Every hour")
        #expect(described.detail == "")
    }

    private func utc(_ iso: String) -> Date {
        let fmt = ISO8601DateFormatter()
        fmt.timeZone = TimeZone(identifier: "UTC")
        return fmt.date(from: iso)!
    }

    private func iso(_ date: Date) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.timeZone = TimeZone(identifier: "UTC")
        return fmt.string(from: date)
    }

    @Test("clock times are read in the routine's zone")
    func nextDateTimezone() {
        // 2026-09-13 is a Sunday; 06:00Z is before every 7am zone below.
        let from = utc("2026-09-13T06:00:00Z")
        #expect(iso(Cron.nextDate("0 7 * * *", from: from, timezone: "UTC")) == "2026-09-13T07:00:00Z")
        #expect(iso(Cron.nextDate("0 7 * * *", from: from, timezone: "America/New_York")) == "2026-09-13T11:00:00Z")
        #expect(iso(Cron.nextDate("0 7 * * *", from: from, timezone: "Asia/Tokyo")) == "2026-09-13T22:00:00Z")
        // Unset or unrecognized means this Mac's zone, matching the time picker.
        let local = Cron.nextDate("0 7 * * *", from: from)
        #expect(iso(local) == iso(Cron.nextDate("0 7 * * *", from: from, timezone: TimeZone.current.identifier)))
        #expect(iso(Cron.nextDate("0 7 * * *", from: from, timezone: "Not/AZone")) == iso(local))
    }

    @Test("day-of-week, day-of-month, and month are honored")
    func nextDateCalendarFields() {
        // Sunday 2026-09-13, 06:00 UTC.
        let sunday = utc("2026-09-13T06:00:00Z")
        // Weekdays skips Sunday and lands on Monday.
        #expect(iso(Cron.nextDate("0 7 * * 1-5", from: sunday, timezone: "UTC")) == "2026-09-14T07:00:00Z")
        // Weekly on Monday, same answer from a Sunday.
        #expect(iso(Cron.nextDate("0 7 * * 1", from: sunday, timezone: "UTC")) == "2026-09-14T07:00:00Z")
        // Sunday is both 0 and 7 in cron; from Monday the next one is the 20th.
        let monday = utc("2026-09-14T06:00:00Z")
        #expect(iso(Cron.nextDate("0 7 * * 0", from: monday, timezone: "UTC")) == "2026-09-20T07:00:00Z")
        #expect(iso(Cron.nextDate("0 7 * * 7", from: monday, timezone: "UTC")) == "2026-09-20T07:00:00Z")
        // Monthly waits for the 1st, not tomorrow.
        #expect(iso(Cron.nextDate("0 7 1 * *", from: sunday, timezone: "UTC")) == "2026-10-01T07:00:00Z")
        // A month field is respected even a year out.
        #expect(iso(Cron.nextDate("0 7 4 7 *", from: sunday, timezone: "UTC")) == "2027-07-04T07:00:00Z")
        // Daily is unchanged.
        #expect(iso(Cron.nextDate("0 7 * * *", from: sunday, timezone: "UTC")) == "2026-09-13T07:00:00Z")
    }

    @Test("restricted day-of-month and day-of-week combine as cron does")
    func nextDateDomOrDow() {
        // Both restricted: either match qualifies. From Sun the 13th, Monday the
        // 14th matches the dow half; the 20th matches the dom half.
        let sunday = utc("2026-09-13T06:00:00Z")
        #expect(iso(Cron.nextDate("0 7 20 * 1", from: sunday, timezone: "UTC")) == "2026-09-14T07:00:00Z")
        let tuesday = utc("2026-09-15T06:00:00Z")
        #expect(iso(Cron.nextDate("0 7 20 * 1", from: tuesday, timezone: "UTC")) == "2026-09-20T07:00:00Z")
    }

    @Test("an unmatchable expression does not spin")
    func nextDateUnmatchable() {
        let from = utc("2026-09-13T06:00:00Z")
        // Hour 99 matches nothing; fall back to a minute out rather than walking years.
        #expect(Cron.nextDate("0 99 * * *", from: from).timeIntervalSince(from) == 60)
        #expect(Cron.nextDate("bogus", from: from).timeIntervalSince(from) == 60)
    }

    @Test("routine backoff doubles then caps")
    func routineBackoff() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(Cron.backoffDate(failCount: 1, from: now).timeIntervalSince(now) == 15 * 60)
        #expect(Cron.backoffDate(failCount: 2, from: now).timeIntervalSince(now) == 30 * 60)
        #expect(Cron.backoffDate(failCount: 3, from: now).timeIntervalSince(now) == 60 * 60)
        #expect(Cron.backoffDate(failCount: 5, from: now).timeIntervalSince(now) == 240 * 60)
        #expect(Cron.backoffDate(failCount: 9, from: now).timeIntervalSince(now) == 240 * 60)
    }
}
