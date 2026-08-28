import Foundation
import Testing
@testable import YMCSKit

@Suite("Alert digest")
struct AlertDigestTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func change(
        _ id: String,
        _ to: DeviceStatus,
        from: DeviceStatus? = .online,
        at offset: TimeInterval = 0,
        cause: StatusChange.Cause = .observed,
        name: String? = nil
    ) -> StatusChange {
        StatusChange(
            device: .stub(id, to, name: name),
            from: from,
            to: to,
            at: start.addingTimeInterval(offset),
            cause: cause
        )
    }

    /// Wraps the mutating flush so it can be used inside a macro expansion.
    private func flushed(_ digest: inout AlertDigest, at moment: Date) -> AlertDigest.Mail? {
        digest.flush(at: moment)
    }

    private func digest(
        window: Duration = .seconds(60),
        maximumPerHour: Int = 12,
        includesRecoveries: Bool = true
    ) -> AlertDigest {
        var configuration = AlertDigest.Configuration()
        configuration.window = window
        configuration.maximumPerHour = maximumPerHour
        configuration.includesRecoveries = includesRecoveries
        return AlertDigest(configuration: configuration)
    }

    @Test("Nothing is sent before the window closes")
    func waitsForTheWindow() {
        var digest = digest(window: .seconds(60))
        digest.add(change("1", .offline), at: start)

        #expect(flushed(&digest, at: start.addingTimeInterval(59)) == nil)
        #expect(flushed(&digest, at: start.addingTimeInterval(60)) != nil)
    }

    @Test("A site-wide failure becomes one email, not forty")
    func coalescesManyChanges() throws {
        var digest = digest(window: .seconds(60))
        for index in 1...40 {
            digest.add(change("\(index)", .offline, at: 1), at: start.addingTimeInterval(1))
        }

        let mailResult = digest.flush(at: start.addingTimeInterval(120))
        let mail = try #require(mailResult)
        #expect(mail.changes.count == 40)
        #expect(mail.subject == "40 phones offline")
        #expect(digest.pendingCount == 0)
    }

    @Test("A phone that flaps inside one window is reported once, at its latest state")
    func collapsesRepeatsPerDevice() throws {
        var digest = digest(window: .seconds(60))
        digest.add(change("1", .offline, at: 0), at: start)
        digest.add(change("1", .online, from: .offline, at: 10), at: start.addingTimeInterval(10))

        let mailResult = digest.flush(at: start.addingTimeInterval(120))
        let mail = try #require(mailResult)
        // Otherwise the email says the phone is both down and up.
        #expect(mail.changes.count == 1)
        #expect(mail.changes[0].to == .online)
    }

    @Test("A restart this app performed never becomes an email")
    func ignoresRebootCausedChanges() {
        var digest = digest(window: .seconds(60))
        digest.add(change("1", .offline, cause: .reboot), at: start)

        #expect(digest.pendingCount == 0)
        #expect(flushed(&digest, at: start.addingTimeInterval(600)) == nil)
    }

    @Test("Recoveries can be excluded without affecting outages")
    func recoveriesAreOptional() throws {
        var digest = digest(window: .seconds(60), includesRecoveries: false)
        digest.add(change("1", .online, from: .offline), at: start)
        digest.add(change("2", .offline), at: start)

        let mailResult = digest.flush(at: start.addingTimeInterval(120))
        let mail = try #require(mailResult)
        #expect(mail.changes.map(\.device.id) == ["2"])
    }

    @Test("The hourly cap holds a batch rather than dropping it")
    func capHoldsRatherThanDrops() throws {
        var digest = digest(window: .seconds(0), maximumPerHour: 1)
        digest.add(change("1", .offline, at: 0), at: start)
        let firstSend = digest.flush(at: start)
        _ = try #require(firstSend)

        digest.add(change("2", .offline, at: 10), at: start.addingTimeInterval(10))
        // Capped, so nothing goes now -- but nothing is lost either.
        #expect(flushed(&digest, at: start.addingTimeInterval(20)) == nil)
        #expect(digest.pendingCount == 1)

        let laterResult = digest.flush(at: start.addingTimeInterval(3601))
        let later = try #require(laterResult)
        #expect(later.changes.map(\.device.id) == ["2"])
        // A delayed summary that did not say so would misrepresent its own times.
        #expect(later.wasDelayedByCap)
        #expect(later.body.contains("held back"))
    }

    @Test("A held batch keeps accumulating instead of sending one email per change")
    func heldBatchAccumulates() throws {
        var digest = digest(window: .seconds(0), maximumPerHour: 1)
        digest.add(change("1", .offline), at: start)
        let firstSend = digest.flush(at: start)
        _ = try #require(firstSend)

        for index in 2...5 {
            digest.add(change("\(index)", .offline, at: 10), at: start.addingTimeInterval(10))
            #expect(flushed(&digest, at: start.addingTimeInterval(10)) == nil)
        }

        let laterResult = digest.flush(at: start.addingTimeInterval(3601))
        let later = try #require(laterResult)
        #expect(later.changes.count == 4)
    }

    @Test("nextFlush says when there is something to do, and nothing when there is not")
    func nextFlushSchedule() {
        var digest = digest(window: .seconds(60))
        #expect(digest.nextFlush(after: start) == nil)

        digest.add(change("1", .offline), at: start)
        #expect(digest.nextFlush(after: start) == start.addingTimeInterval(60))
    }

    @Test("A single change gets a subject naming the phone")
    func singleChangeSubject() throws {
        var digest = digest(window: .seconds(0))
        digest.add(change("1", .offline, name: "Reception"), at: start)

        let mailResult = digest.flush(at: start)
        let mail = try #require(mailResult)
        #expect(mail.subject == "Reception went offline")
        #expect(mail.body.contains("Reception"))
    }

    @Test("A mixed batch counts both directions in the subject")
    func mixedSubject() throws {
        var digest = digest(window: .seconds(0))
        digest.add(change("1", .offline, name: "Reception"), at: start)
        digest.add(change("2", .online, from: .offline, name: "Workshop"), at: start)

        let mailResult = digest.flush(at: start)
        let mail = try #require(mailResult)
        #expect(mail.subject == "1 phone offline, 1 recovered")
        #expect(mail.body.contains("Offline:"))
        #expect(mail.body.contains("Back online:"))
    }

    @Test("Outages are listed before recoveries")
    func outagesFirst() throws {
        var digest = digest(window: .seconds(0))
        digest.add(change("1", .online, from: .offline, name: "Aaa recovered"), at: start)
        digest.add(change("2", .offline, name: "Zzz down"), at: start)

        let mailResult = digest.flush(at: start)
        let mail = try #require(mailResult)
        #expect(mail.changes[0].device.id == "2")
    }

    @Test("Flushing an empty digest produces nothing")
    func emptyFlush() {
        var digest = digest()
        #expect(flushed(&digest, at: start) == nil)
    }
}
