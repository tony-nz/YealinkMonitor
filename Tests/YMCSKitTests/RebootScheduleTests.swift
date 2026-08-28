import Foundation
import Testing
@testable import YMCSKit

@Suite("Reboot schedules")
struct RebootScheduleTests {
    /// Auckland: chosen because it has daylight saving, which is what breaks
    /// naive "add 86,400 seconds" scheduling.
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Pacific/Auckland")!
        return calendar
    }

    private func date(_ string: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: string)!
    }

    private func schedule(
        hour: Int = 3,
        minute: Int = 0,
        weekdays: Set<Int> = [],
        devices: [String] = ["1"],
        enabled: Bool = true,
        lastFired: Date? = nil
    ) -> RebootSchedule {
        RebootSchedule(
            name: "Nightly",
            deviceIDs: devices,
            hour: hour,
            minute: minute,
            weekdays: weekdays,
            isEnabled: enabled,
            lastFired: lastFired
        )
    }

    @Test("A daily schedule fires at the same wall clock time tomorrow")
    func dailyNextFire() {
        let next = schedule().nextFireDate(after: date("2026-03-01 12:00"), calendar: calendar)
        #expect(next == date("2026-03-02 03:00"))
    }

    @Test("The time of day survives a daylight saving change")
    func acrossDaylightSaving() {
        // New Zealand ends daylight saving on 2026-04-05, so this day is 25
        // hours long. Adding 86,400 seconds would land at 02:00.
        let next = schedule().nextFireDate(after: date("2026-04-04 12:00"), calendar: calendar)
        #expect(next == date("2026-04-05 03:00"))

        let components = calendar.dateComponents([.hour, .minute], from: next!)
        #expect(components.hour == 3)
        #expect(components.minute == 0)
    }

    @Test("A weekday schedule skips the days it was not given")
    func weekdaysOnly() {
        // 2 = Monday, 6 = Friday.
        let mondaysAndFridays = schedule(weekdays: [2, 6])
        // 2026-03-03 is a Tuesday.
        let next = mondaysAndFridays.nextFireDate(after: date("2026-03-03 12:00"), calendar: calendar)
        #expect(next == date("2026-03-06 03:00"))
    }

    @Test("A disabled schedule has no next fire date at all")
    func disabledNeverFires() {
        #expect(schedule(enabled: false).nextFireDate(after: date("2026-03-01 12:00"), calendar: calendar) == nil)
    }

    @Test("An occurrence a few minutes ago is due, and reports how late it is")
    func recentOccurrenceIsDue() {
        let due = schedule().due(at: date("2026-03-02 03:05"), grace: 3600, calendar: calendar)
        #expect(due == .due(occurrence: date("2026-03-02 03:00"), lateBy: 300))
    }

    @Test("An occurrence older than the grace window is missed, not run late")
    func staleOccurrenceIsMissed() {
        // The Mac was closed at 3am and opened at 10am. Restarting the phones on
        // discovery would be an unannounced mid-morning outage.
        let due = schedule().due(at: date("2026-03-02 10:00"), grace: 3600, calendar: calendar)
        #expect(due == .missed(occurrence: date("2026-03-02 03:00")))
    }

    @Test("An occurrence already fired is not fired again")
    func firedOccurrenceIsNotRepeated() {
        let fired = schedule(lastFired: date("2026-03-02 03:00"))
        #expect(fired.due(at: date("2026-03-02 03:30"), grace: 3600, calendar: calendar) == .notDue)
    }

    @Test("Yesterday's run does not satisfy today's occurrence")
    func nextDayIsDueAgain() {
        let fired = schedule(lastFired: date("2026-03-02 03:00"))
        let due = fired.due(at: date("2026-03-03 03:01"), grace: 3600, calendar: calendar)
        #expect(due == .due(occurrence: date("2026-03-03 03:00"), lateBy: 60))
    }

    @Test("A schedule with no devices never fires")
    func emptyScheduleNeverFires() {
        let empty = schedule(devices: [])
        #expect(empty.due(at: date("2026-03-02 03:05"), grace: 3600, calendar: calendar) == .notDue)
    }

    @Test("Exactly on the minute counts as due")
    func exactlyOnTime() {
        let due = schedule().due(at: date("2026-03-02 03:00"), grace: 3600, calendar: calendar)
        #expect(due == .due(occurrence: date("2026-03-02 03:00"), lateBy: 0))
    }

    @Test("Schedules survive a round trip through JSON")
    func codable() throws {
        var original = schedule(hour: 2, minute: 30, weekdays: [2, 4])
        original.lastFired = date("2026-03-02 02:30")
        original.lastOutcome = .fired(total: 3, succeeded: 2, failed: 1)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RebootSchedule.self, from: data)

        #expect(decoded == original)
        #expect(decoded.lastOutcome?.isFailure == true)
    }
}
