import Foundation
import Testing
@testable import YMCSKit

@Suite("Transition detection")
struct TransitionTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("The first poll establishes a baseline without alerting")
    func firstPollIsSilent() {
        var detector = TransitionDetector(confirmations: 2)
        #expect(!detector.hasBaseline)
        // Two phones are already offline when the app launches. Alerting here
        // would mean a burst of notifications on every login.
        let changes = detector.ingest(
            [.stub("1", .online), .stub("2", .offline), .stub("3", .offline)],
            at: t0
        )
        #expect(changes.isEmpty)
        #expect(detector.hasBaseline)
        #expect(detector.confirmedStatuses["2"] == .offline)
    }

    @Test("Going offline requires consecutive confirmations")
    func offlineIsDebounced() {
        var detector = TransitionDetector(confirmations: 2)
        detector.ingest([.stub("1", .online)], at: t0)

        // One missed check-in is not an outage.
        #expect(detector.ingest([.stub("1", .offline)], at: t0).isEmpty)
        #expect(detector.confirmedStatuses["1"] == .online)

        let changes = detector.ingest([.stub("1", .offline)], at: t0)
        #expect(changes.count == 1)
        #expect(changes[0].from == .online)
        #expect(changes[0].to == .offline)
        #expect(changes[0].isRegression)
    }

    @Test("A device that flaps back before confirmation is never reported")
    func flappingIsSuppressed() {
        var detector = TransitionDetector(confirmations: 3)
        detector.ingest([.stub("1", .online)], at: t0)

        #expect(detector.ingest([.stub("1", .offline)], at: t0).isEmpty)
        #expect(detector.ingest([.stub("1", .offline)], at: t0).isEmpty)
        // Recovered on the third poll: the user is never told anything happened.
        #expect(detector.ingest([.stub("1", .online)], at: t0).isEmpty)
        // And the candidate counter is cleared, so a later single miss does not
        // inherit the earlier count and fire immediately.
        #expect(detector.ingest([.stub("1", .offline)], at: t0).isEmpty)
    }

    @Test("Alternating between two bad statuses does not accumulate confirmations")
    func candidateResetsOnStatusChange() {
        var detector = TransitionDetector(confirmations: 2)
        detector.ingest([.stub("1", .online)], at: t0)
        #expect(detector.ingest([.stub("1", .offline)], at: t0).isEmpty)
        // A different status restarts the count rather than confirming offline.
        #expect(detector.ingest([.stub("1", .pending)], at: t0).isEmpty)
        let changes = detector.ingest([.stub("1", .pending)], at: t0)
        #expect(changes.first?.to == .pending)
    }

    @Test("Recovery is reported on the first poll that sees it")
    func recoveryIsImmediate() {
        var detector = TransitionDetector(confirmations: 3)
        detector.ingest([.stub("1", .offline)], at: t0)

        let changes = detector.ingest([.stub("1", .online)], at: t0)
        #expect(changes.count == 1)
        #expect(changes[0].isRecovery)
        #expect(changes[0].from == .offline)
    }

    @Test("A newly added device is reported only if it arrives unhealthy")
    func newDevices() {
        var detector = TransitionDetector(confirmations: 2)
        detector.ingest([.stub("1", .online)], at: t0)

        let healthy = detector.ingest([.stub("1", .online), .stub("2", .online)], at: t0)
        #expect(healthy.isEmpty)

        let unhealthy = detector.ingest(
            [.stub("1", .online), .stub("2", .online), .stub("3", .pending)],
            at: t0
        )
        #expect(unhealthy.count == 1)
        #expect(unhealthy[0].from == nil)
        #expect(unhealthy[0].to == .pending)
    }

    @Test("Deleting a device from YMCS is not an outage")
    func removalIsSilent() {
        var detector = TransitionDetector(confirmations: 2)
        detector.ingest([.stub("1", .online), .stub("2", .online)], at: t0)

        #expect(detector.ingest([.stub("1", .online)], at: t0).isEmpty)
        #expect(detector.confirmedStatuses["2"] == nil)

        // Re-adding it later starts clean rather than replaying a stale status.
        #expect(detector.ingest([.stub("1", .online), .stub("2", .online)], at: t0).isEmpty)
    }

    @Test("confirmations: 1 disables debouncing")
    func noDebounce() {
        var detector = TransitionDetector(confirmations: 1)
        detector.ingest([.stub("1", .online)], at: t0)
        #expect(detector.ingest([.stub("1", .offline)], at: t0).count == 1)
    }

    @Test("Reset clears the baseline so the next poll is silent again")
    func reset() {
        var detector = TransitionDetector(confirmations: 1)
        detector.ingest([.stub("1", .online)], at: t0)
        detector.reset()
        #expect(!detector.hasBaseline)
        #expect(detector.ingest([.stub("1", .offline)], at: t0).isEmpty)
    }
}
