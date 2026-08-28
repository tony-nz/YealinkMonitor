import Foundation
import SMTPKit
import YMCSKit

/// Turns confirmed status changes into email.
///
/// Two things make this more than a call to `SMTPSender`. The first is the
/// digest: alerts are batched so a site-wide fault sends one message. The second
/// is that failures have to be loud -- a monitor whose alerting silently stopped
/// working is worse than no monitor -- so sends are retried with a backoff and
/// the last error is surfaced in the UI rather than swallowed.
@MainActor
@Observable
final class EmailAlerter {
    /// A message waiting to go out, with its retry state.
    private struct Outgoing: Identifiable {
        let id = UUID()
        let subject: String
        let body: String
        var attempts: Int
        var nextAttempt: Date
    }

    private(set) var lastError: String?
    private(set) var lastSentAt: Date?
    private(set) var isSending = false

    private var digest = AlertDigest()
    private var outbox: [Outgoing] = []
    /// The settings in force. Kept here rather than captured by the tick task,
    /// which would otherwise keep retrying against a server the user has since
    /// changed.
    private var settings = AppSettings()
    private var tickTask: Task<Void, Never>?
    private let sender: SMTPSender
    private let now: () -> Date

    /// Give up after this many attempts. The changes are still in the history
    /// and still on screen; only the email is abandoned.
    private static let maximumAttempts = 5

    init(sender: SMTPSender = SMTPSender(), now: @escaping () -> Date = { Date() }) {
        self.sender = sender
        self.now = now
    }

    var hasPendingWork: Bool { digest.pendingCount > 0 || !outbox.isEmpty }

    func update(settings: AppSettings) {
        self.settings = settings
        digest.configuration = settings.alertDigestConfiguration
    }

    /// Offers a change for emailing. Everything that decides *not* to email is
    /// here or in the digest, so there is one place to look when an expected
    /// alert did not arrive.
    func receive(_ change: StatusChange, settings: AppSettings) {
        update(settings: settings)
        guard settings.emailEnabled, settings.isEmailConfigured else { return }
        guard !settings.archivedDeviceIDs.contains(change.device.id) else { return }
        guard !settings.mutedDeviceIDs.contains(change.device.id) else { return }
        if settings.emailRespectsQuietHours && settings.isQuietHour(now()) { return }

        digest.add(change, at: now())
        startTicking()
    }

    /// Queues a message that is not a status change -- the report from a
    /// scheduled restart, say. It goes through the same outbox, so it gets the
    /// same retries, but it is not batched: it describes one event and delaying
    /// it would not merge it with anything.
    func enqueue(subject: String, body: String, settings: AppSettings) {
        update(settings: settings)
        guard settings.emailEnabled, settings.isEmailConfigured else { return }
        outbox.append(Outgoing(subject: subject, body: body, attempts: 0, nextAttempt: now()))
        startTicking()
    }

    /// Sends a message immediately, bypassing the digest. Used by the test
    /// button in Settings, where the whole point is an answer now.
    func sendTest(settings: AppSettings) async -> String? {
        let message = SMTPMessage(
            from: settings.emailFrom,
            fromName: "YealinkMonitor",
            to: settings.emailRecipients,
            subject: "YealinkMonitor test",
            body: """
                This is a test from YealinkMonitor on \(Host.current().localizedName ?? "this Mac").

                If you received it, outage alerts will reach you the same way.
                """
        )
        do {
            try await deliver(message, settings: settings)
            lastError = nil
            lastSentAt = now()
            return nil
        } catch {
            let described = (error as? SMTPError)?.errorDescription ?? error.localizedDescription
            lastError = described
            return described
        }
    }

    /// Drops anything waiting, e.g. when email is switched off or the account
    /// changes. Queued mail for an old server would only fail forever.
    func reset() {
        digest.reset()
        outbox = []
        tickTask?.cancel()
        tickTask = nil
    }

    // MARK: - Scheduling

    /// A short tick rather than a sleep until the exact deadline: this runs in a
    /// menu bar app that sleeps with the Mac, and a long sleep wakes up wrong.
    private func startTicking() {
        guard tickTask == nil else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self else { return }
                await self.tick()
                if !self.hasPendingWork {
                    self.tickTask = nil
                    return
                }
            }
        }
    }

    private func tick() async {
        if let mail = digest.flush(at: now()) {
            outbox.append(
                Outgoing(subject: mail.subject, body: mail.body, attempts: 0, nextAttempt: now())
            )
        }
        await drainOutbox()
    }

    private func drainOutbox() async {
        guard !isSending else { return }
        guard let index = outbox.firstIndex(where: { $0.nextAttempt <= now() }) else { return }

        isSending = true
        defer { isSending = false }

        let outgoing = outbox[index]
        let message = SMTPMessage(
            from: settings.emailFrom,
            fromName: "YealinkMonitor",
            to: settings.emailRecipients,
            subject: outgoing.subject,
            body: outgoing.body
        )

        do {
            try await deliver(message, settings: settings)
            outbox.removeAll { $0.id == outgoing.id }
            lastSentAt = now()
            lastError = nil
        } catch {
            let described = (error as? SMTPError)?.errorDescription ?? error.localizedDescription
            lastError = described
            guard let current = outbox.firstIndex(where: { $0.id == outgoing.id }) else { return }
            outbox[current].attempts += 1
            if outbox[current].attempts >= Self.maximumAttempts {
                // Keep the error visible; the alert itself is given up on.
                outbox.remove(at: current)
                return
            }
            // 30s, 2m, 8m, 32m: long enough to ride out a restart of the relay,
            // short enough that a fixed problem recovers without user action.
            let backoff = pow(4.0, Double(outbox[current].attempts - 1)) * 30
            outbox[current].nextAttempt = now().addingTimeInterval(backoff)
        }
    }

    private func deliver(_ message: SMTPMessage, settings: AppSettings) async throws {
        guard settings.isEmailConfigured else { throw SMTPError.notConfigured }
        let password = (try? Keychain.readSecret(account: Keychain.smtpAccount)) ?? ""
        let server = settings.smtpServer
        // Off the main actor: this opens a socket and waits on a remote server.
        try await Task.detached(priority: .utility) { [sender] in
            try await sender.send(message, server: server, password: password)
        }.value
    }
}
