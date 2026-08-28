import Foundation
import YMCSKit

/// Fires reboot schedules while the app is running.
///
/// The honest limitation, stated once here and again in the UI: this is a menu
/// bar app, not a daemon. A schedule fires only while the app is running and the
/// Mac is awake. A closed laptop at 3am restarts nothing, and no amount of code
/// in this file changes that -- it would need a LaunchAgent or a server-side
/// scheduler, and YMCS has no scheduling endpoint.
///
/// What this can do is be truthful about it: an occurrence missed by a few
/// minutes runs late and says so, one missed by hours is recorded as skipped
/// rather than fired at a surprising time, and both outcomes are visible in
/// Settings so a schedule that has quietly been skipping for a week is not a
/// secret.
@MainActor
final class RebootScheduler {
    /// How often due schedules are looked for. Cheap: it is arithmetic on a
    /// handful of dates, no network.
    private static let tickInterval = Duration.seconds(30)

    var schedules: () -> [RebootSchedule] = { [] }
    var graceSeconds: () -> TimeInterval = { 3600 }
    /// Performs the restart. Returns what to record.
    var run: (RebootSchedule) async -> RebootSchedule.Outcome = { _ in .skipped(reason: "not configured") }
    /// Persists the result against the schedule.
    var record: (UUID, Date, RebootSchedule.Outcome) -> Void = { _, _, _ in }

    private var tickTask: Task<Void, Never>?
    private var isChecking = false

    func start() {
        guard tickTask == nil else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkNow()
                try? await Task.sleep(for: Self.tickInterval)
            }
        }
    }

    func stop() {
        tickTask?.cancel()
        tickTask = nil
    }

    /// Evaluates every schedule once. Safe to call from a wake-from-sleep hook,
    /// which is exactly when a missed occurrence is discovered.
    func checkNow(at moment: Date = Date()) async {
        // A restart takes a while; without this a slow one would be started
        // again by the next tick.
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        for schedule in schedules() {
            switch schedule.due(at: moment, grace: graceSeconds()) {
            case .notDue:
                continue

            case .missed(let occurrence):
                // Stamped as fired so it is not reconsidered every 30 seconds
                // for the rest of the day, but recorded as skipped so the UI
                // does not claim the phones were restarted.
                record(
                    schedule.id,
                    occurrence,
                    .skipped(reason: "The Mac was asleep or the app was not running at \(Self.timeText(occurrence)).")
                )

            case .due(let occurrence, let lateBy):
                let outcome = await run(schedule)
                record(schedule.id, occurrence, Self.annotate(outcome, lateBy: lateBy))
            }
        }
    }

    /// Reports lateness only when it is worth reporting. Everything is a few
    /// seconds late; a schedule that ran 40 minutes after the Mac woke up is a
    /// different matter.
    private static func annotate(_ outcome: RebootSchedule.Outcome, lateBy: TimeInterval) -> RebootSchedule.Outcome {
        guard lateBy >= 300, case .fired = outcome else { return outcome }
        return .firedLate(minutes: Int(lateBy / 60))
    }

    private static func timeText(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
