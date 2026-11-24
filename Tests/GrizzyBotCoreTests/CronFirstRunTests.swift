import Foundation
import Testing
@testable import GrizzyBotCore

@Suite struct CronFirstRunTests {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private func date(_ d: Int, _ h: Int, _ m: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 11, day: d, hour: h, minute: m))!
    }

    @Test func dailyRoutineFiresEveryFutureDayButNotPastOnes() {
        let now = date(22, 10)
        func run(_ day: Int) -> Date? {
            Cron.firstRun(on: date(day, 12), cron: "0 9 * * *", notBefore: now, timezone: "UTC", calendar: cal)
        }
        #expect(run(21) == nil, "a day already gone")
        #expect(run(22) == nil, "today's 9:00 has passed")
        #expect(run(23) == date(23, 9))
        #expect(run(29) == date(29, 9))
    }

    @Test func weekdaysSkipTheWeekend() {
        let now = date(22, 10) // Sunday
        func run(_ day: Int) -> Date? {
            Cron.firstRun(on: date(day, 12), cron: "0 9 * * 1-5", notBefore: now, timezone: "UTC", calendar: cal)
        }
        #expect(run(23) != nil) // Monday
        #expect(run(28) == nil) // Saturday
        #expect(run(29) == nil) // Sunday
    }

    @Test func todayCountsWhenStillAhead() {
        let r = Cron.firstRun(on: date(22, 8), cron: "30 18 * * *", notBefore: date(22, 10), timezone: "UTC", calendar: cal)
        #expect(r == date(22, 18, 30))
    }

    @Test func eventOnlyNeverAppears() {
        #expect(Cron.firstRun(on: date(23, 12), cron: "", notBefore: date(22, 10), timezone: "UTC", calendar: cal) == nil)
    }
}
