import Foundation

/// A standing instruction to restart a fixed set of phones at a fixed time.
///
/// The device list is explicit and stored by id. A schedule defined by a filter
/// -- "everything at this site" -- silently grows as phones are added, which
/// turns into a fleet-wide restart nobody authored.
public struct RebootSchedule: Codable, Sendable, Identifiable, Hashable {
    /// What happened the last time this schedule came due.
    public enum Outcome: Codable, Sendable, Hashable {
        case fired(total: Int, succeeded: Int, failed: Int)
        /// Fired later than intended, e.g. the Mac was asleep at the time.
        case firedLate(minutes: Int)
        /// Missed entirely and deliberately not run.
        case skipped(reason: String)
        case failed(message: String)
    }

    public var id: UUID
    public var name: String
    public var deviceIDs: [String]
    /// Local time of day.
    public var hour: Int
    public var minute: Int
    /// `Calendar` weekday numbers, 1 = Sunday. Empty means every day.
    public var weekdays: Set<Int>
    public var isEnabled: Bool
    public var lastFired: Date?
    public var lastOutcome: Outcome?

    public init(
        id: UUID = UUID(),
        name: String = "",
        deviceIDs: [String] = [],
        hour: Int = 3,
        minute: Int = 0,
        weekdays: Set<Int> = [],
        isEnabled: Bool = true,
        lastFired: Date? = nil,
        lastOutcome: Outcome? = nil
    ) {
        self.id = id
        self.name = name
        self.deviceIDs = deviceIDs
        self.hour = hour
        self.minute = minute
        self.weekdays = weekdays
        self.isEnabled = isEnabled
        self.lastFired = lastFired
        self.lastOutcome = lastOutcome
    }

    private var matchedWeekdays: Set<Int> {
        weekdays.isEmpty ? Set(1...7) : weekdays
    }

    private func components(weekday: Int) -> DateComponents {
        DateComponents(hour: hour, minute: minute, weekday: weekday)
    }

    /// The next time this schedule is due.
    ///
    /// Computed with `Calendar` rather than by adding 86,400 seconds, so a
    /// 03:00 restart stays at 03:00 across a daylight saving change instead of
    /// drifting to 02:00 or 04:00.
    public func nextFireDate(after date: Date, calendar: Calendar = .current) -> Date? {
        guard isEnabled else { return nil }
        return matchedWeekdays.compactMap {
            calendar.nextDate(
                after: date,
                matching: components(weekday: $0),
                matchingPolicy: .nextTime
            )
        }.min()
    }

    /// The most recent time this schedule was due, at or before `date`.
    public func previousFireDate(atOrBefore date: Date, calendar: Calendar = .current) -> Date? {
        // Searching backwards is strict, so nudge forward a second to let an
        // exact hit count as due rather than as an hour ago.
        let from = date.addingTimeInterval(1)
        return matchedWeekdays.compactMap {
            calendar.nextDate(
                after: from,
                matching: components(weekday: $0),
                matchingPolicy: .nextTime,
                direction: .backward
            )
        }.max()
    }

    /// What this schedule should do right now.
    ///
    /// The grace window is the whole point. A menu bar app cannot fire while the
    /// Mac is asleep, so an occurrence is routinely discovered late. Running it a
    /// few minutes late is helpful; running last Tuesday's 3am restart at 10am
    /// on Thursday is a surprise outage.
    public enum Due: Equatable {
        case notDue
        case due(occurrence: Date, lateBy: TimeInterval)
        case missed(occurrence: Date)
    }

    public func due(
        at now: Date,
        grace: TimeInterval = 3600,
        calendar: Calendar = .current
    ) -> Due {
        guard isEnabled, !deviceIDs.isEmpty else { return .notDue }
        guard let occurrence = previousFireDate(atOrBefore: now, calendar: calendar) else { return .notDue }
        // Already handled: `lastFired` is stamped whether it ran or was skipped.
        if let lastFired, lastFired >= occurrence { return .notDue }

        let lateBy = now.timeIntervalSince(occurrence)
        return lateBy > grace ? .missed(occurrence: occurrence) : .due(occurrence: occurrence, lateBy: lateBy)
    }
}

extension RebootSchedule.Outcome {
    public var isFailure: Bool {
        switch self {
        case .failed: true
        case .fired(_, _, let failed): failed > 0
        case .firedLate, .skipped: false
        }
    }
}
