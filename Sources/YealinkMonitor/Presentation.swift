import SwiftUI
import YMCSKit

extension DeviceStatus {
    var label: String {
        switch self {
        case .online: "Online"
        case .offline: "Offline"
        case .pending: "Never reported"
        case .unknown(let raw): raw.capitalized
        }
    }

    var symbolName: String {
        switch self {
        case .online: "checkmark.circle.fill"
        case .offline: "exclamationmark.triangle.fill"
        case .pending: "questionmark.circle.fill"
        case .unknown: "circle.dashed"
        }
    }

    var tint: Color {
        switch self {
        case .online: .green
        case .offline: .red
        case .pending: .orange
        case .unknown: .secondary
        }
    }
}

extension AccountStatus {
    var label: String {
        switch self {
        case .registered: "Registered"
        case .doNotDisturb: "Do not disturb"
        case .unregistered: "Not registered"
        case .unknown: "Unknown"
        }
    }

    var tint: Color {
        switch self {
        case .registered: .green
        case .doNotDisturb: .blue
        case .unregistered: .red
        case .unknown: .secondary
        }
    }
}

extension Alarm.Level {
    var label: String {
        switch self {
        case .minor: "Minor"
        case .major: "Major"
        case .critical: "Critical"
        }
    }

    var tint: Color {
        switch self {
        case .minor: .yellow
        case .major: .orange
        case .critical: .red
        }
    }

    var symbolName: String {
        switch self {
        case .minor: "exclamationmark.circle"
        case .major: "exclamationmark.triangle"
        case .critical: "exclamationmark.octagon.fill"
        }
    }
}

extension Alarm {
    /// Ranks alarms worst-first. Unknown levels sort last rather than first, so
    /// a level this app does not recognise cannot masquerade as critical.
    var severityRank: Int { level?.rawValue ?? 0 }
}

extension CallRecord.Quality? {
    /// Nil quality is grey, not green: an unscored call is not a good call.
    var tint: Color {
        switch self {
        case .good: .green
        case .poor: .orange
        case .bad: .red
        case .unknown, nil: .secondary
        }
    }
}

extension StatusChange {
    /// What the history row says. A drop this app caused by restarting the phone
    /// reads as a restart, not as an outage -- otherwise the history invents a
    /// reliability problem that does not exist.
    var historyLabel: String {
        switch (cause, to) {
        case (.reboot, .offline), (.reboot, .pending): "Restarting"
        case (.reboot, .online): "Back after restart"
        default: to.label
        }
    }

    var historySymbolName: String {
        cause == .reboot ? "restart.circle" : to.symbolName
    }
}

enum Format {
    static func relative(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }

    static func time(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .omitted, time: .shortened)
    }

    static func callDuration(_ seconds: Int64?) -> String {
        guard let seconds, seconds > 0 else { return "—" }
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m \(seconds % 60)s"
    }

    /// MOS runs 1-5. Two decimal places is false precision; one is enough to
    /// tell 4.3 from 3.6.
    static func mos(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value.formatted(.number.precision(.fractionLength(1)))
    }

    /// For files rather than for people: sorts correctly in a spreadsheet and
    /// does not change shape with the reader's locale.
    static func iso(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().dateTimeSeparator(.space).time(includingFractionalSeconds: false))
    }

    static func dateTime(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

/// A coloured dot plus label, used everywhere a status is shown so the two
/// never drift apart.
struct StatusBadge: View {
    let status: DeviceStatus
    var showsLabel = true

    var body: some View {
        Label {
            if showsLabel { Text(status.label) }
        } icon: {
            Image(systemName: status.symbolName)
                .foregroundStyle(status.tint)
        }
        .labelStyle(.titleAndIcon)
    }
}
