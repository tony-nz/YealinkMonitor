import Foundation

/// Batches confirmed status changes into one email instead of forty.
///
/// A switch failure takes a whole site offline inside one poll. Sending one
/// message per phone would fill an inbox, and would very likely get the sending
/// account throttled by its own provider -- so changes are collected for a short
/// window and sent as a single summary.
///
/// The hourly cap works by holding the batch rather than dropping it: nothing is
/// discarded, it just waits for a slot. A flapping phone therefore costs one
/// delayed email rather than sixty.
public struct AlertDigest: Sendable {
    public struct Configuration: Sendable {
        /// How long to gather changes before sending. Longer means fewer, fuller
        /// emails and a slower first alert.
        public var window: Duration = .seconds(60)
        /// Upper bound on messages sent in any rolling hour.
        public var maximumPerHour: Int = 12
        /// Whether recoveries are worth an email at all.
        public var includesRecoveries: Bool = true

        public init() {}
    }

    /// One email, ready to send.
    public struct Mail: Sendable, Equatable {
        public let subject: String
        public let body: String
        public let changes: [StatusChange]
        /// True when the cap held this batch back, which the body says out loud.
        public let wasDelayedByCap: Bool
    }

    public var configuration: Configuration

    private var pending: [StatusChange] = []
    private var pendingSince: Date?
    private var recentSends: [Date] = []
    private var heldByCap = false

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public var pendingCount: Int { pending.count }

    /// Accepts a change for the next batch.
    ///
    /// Changes this app caused by restarting a phone are dropped here rather
    /// than at the sending end, so a scheduled overnight restart cannot produce
    /// an email at all.
    public mutating func add(_ change: StatusChange, at moment: Date) {
        guard change.cause == .observed else { return }
        if change.isRecovery && !configuration.includesRecoveries { return }
        if pending.isEmpty { pendingSince = moment }
        // A device that changes twice inside one window is reported once, at its
        // latest state -- otherwise the email contradicts itself.
        pending.removeAll { $0.device.id == change.device.id }
        pending.append(change)
    }

    /// When `flush` will next produce something, or nil if there is nothing
    /// waiting. The caller uses this to schedule a wake-up.
    public func nextFlush(after moment: Date) -> Date? {
        guard let pendingSince else { return nil }
        let windowEnds = pendingSince.addingTimeInterval(Double(configuration.window.components.seconds))
        return max(windowEnds, earliestAllowedSend(at: moment))
    }

    /// Returns a message when the window has closed and the cap allows it.
    /// Otherwise returns nil and keeps everything for later.
    public mutating func flush(at moment: Date) -> Mail? {
        guard !pending.isEmpty, let deadline = nextFlush(after: moment), moment >= deadline else {
            if pendingSince != nil, moment < earliestAllowedSend(at: moment) { heldByCap = true }
            return nil
        }

        let changes = pending.sorted { lhs, rhs in
            if lhs.isRegression != rhs.isRegression { return lhs.isRegression }
            return lhs.device.displayName.localizedStandardCompare(rhs.device.displayName) == .orderedAscending
        }
        let mail = Mail(
            subject: Self.subject(for: changes),
            body: Self.body(for: changes, at: moment, wasDelayed: heldByCap),
            changes: changes,
            wasDelayedByCap: heldByCap
        )

        pending = []
        pendingSince = nil
        heldByCap = false
        recentSends.append(moment)
        recentSends.removeAll { moment.timeIntervalSince($0) > 3600 }
        return mail
    }

    /// Discards anything waiting, e.g. when email is turned off.
    public mutating func reset() {
        pending = []
        pendingSince = nil
        heldByCap = false
    }

    private func earliestAllowedSend(at moment: Date) -> Date {
        let inLastHour = recentSends.filter { moment.timeIntervalSince($0) <= 3600 }
        guard inLastHour.count >= configuration.maximumPerHour,
              let oldest = inLastHour.min()
        else { return .distantPast }
        // A slot frees exactly one hour after the oldest send in the window.
        return oldest.addingTimeInterval(3600)
    }

    // MARK: - Composition

    static func subject(for changes: [StatusChange]) -> String {
        let down = changes.count { $0.isRegression }
        let up = changes.count { $0.isRecovery }

        if changes.count == 1, let only = changes.first {
            switch only.to {
            case .online: return "\(only.device.displayName) is back online"
            case .offline: return "\(only.device.displayName) went offline"
            case .pending: return "\(only.device.displayName) has never reported in"
            case .unknown(let raw): return "\(only.device.displayName) reported status \(raw)"
            }
        }

        var parts: [String] = []
        if down > 0 { parts.append("\(down) phone\(down == 1 ? "" : "s") offline") }
        if up > 0 { parts.append("\(up) recovered") }
        return parts.isEmpty ? "\(changes.count) phones changed status" : parts.joined(separator: ", ")
    }

    static func body(for changes: [StatusChange], at moment: Date, wasDelayed: Bool) -> String {
        var lines: [String] = []

        let regressions = changes.filter(\.isRegression)
        let recoveries = changes.filter(\.isRecovery)

        if !regressions.isEmpty {
            lines.append(regressions.count == 1 ? "Offline:" : "Offline (\(regressions.count)):")
            lines.append(contentsOf: regressions.map { "  \(line(for: $0))" })
        }
        if !recoveries.isEmpty {
            if !lines.isEmpty { lines.append("") }
            lines.append(recoveries.count == 1 ? "Back online:" : "Back online (\(recoveries.count)):")
            lines.append(contentsOf: recoveries.map { "  \(line(for: $0))" })
        }
        let other = changes.filter { !$0.isRegression && !$0.isRecovery }
        if !other.isEmpty {
            if !lines.isEmpty { lines.append("") }
            lines.append("Other changes:")
            lines.append(contentsOf: other.map { "  \(line(for: $0))" })
        }

        if wasDelayed {
            lines.append("")
            // Otherwise a delayed email silently misrepresents when this happened.
            lines.append("This summary was held back to stay inside the hourly email limit, so some of the times above are older than the time this was sent.")
        }

        lines.append("")
        lines.append("Sent by YealinkMonitor at \(Self.timestamp(moment)).")
        return lines.joined(separator: "\n")
    }

    private static func line(for change: StatusChange) -> String {
        var parts = [change.device.displayName, Device.formatMAC(change.device.mac)]
        parts.append("at \(timestamp(change.at))")
        return parts.joined(separator: " — ")
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
