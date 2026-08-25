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
