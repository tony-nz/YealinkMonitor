import SwiftUI
import YMCSKit

/// The popover behind the menu bar icon: what is broken, right now.
struct MenuBarContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 340)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(summaryLine)
                    .font(.headline)
                Text(freshnessLine)
                    .font(.caption)
                    .foregroundStyle(model.isStale ? .orange : .secondary)
            }
            Spacer()
            Button {
                model.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh now")
            .disabled(model.snapshot.isPolling)
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        if !model.settings.isConfigured {
            message(
                "No credentials yet",
                detail: "Add your YMCS Client ID and Secret to start monitoring.",
                symbol: "key"
            )
        } else if let failure = model.snapshot.failure, failure.needsAttention {
            message(failure.message, detail: "Check Settings.", symbol: "exclamationmark.triangle")
        } else if model.snapshot.devices.isEmpty {
            message(
                model.snapshot.lastSuccess == nil ? "Connecting…" : "No devices found",
                detail: nil,
                symbol: "phone.down"
            )
        } else if model.problems.isEmpty {
            message(
                "All \(model.snapshot.devices.count) phones online",
                detail: model.mutedProblems.isEmpty
                    ? nil
                    : "\(model.mutedProblems.count) muted device\(model.mutedProblems.count == 1 ? "" : "s") not shown.",
                symbol: "checkmark.circle"
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.problems) { device in
                        DeviceRow(device: device)
                        if device.id != model.problems.last?.id { Divider() }
                    }
                }
            }
            .frame(maxHeight: 320)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button("All Phones…") {
                openWindow(id: DevicesWindowID)
                // An accessory-policy app does not get focus for free, so the
                // window would otherwise open behind whatever is in front.
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("Settings…") {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            }
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(12)
    }

    private func message(_ title: String, detail: String?, symbol: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(title).font(.callout)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var summaryLine: String {
        let snapshot = model.snapshot
        guard snapshot.lastSuccess != nil else { return "YealinkMonitor" }
        let problems = model.problems.count
        if problems == 0 { return "All phones online" }
        return "\(problems) phone\(problems == 1 ? "" : "s") need attention"
    }

    /// Never claims the data is current when it is not: a monitor that lies
    /// about freshness is worse than no monitor.
    private var freshnessLine: String {
        if let failure = model.snapshot.failure, !failure.needsAttention {
            if let retryAfter = failure.retryAfter {
                return "Rate limited — retrying in \(retryAfter.components.seconds)s"
            }
            return "Last check failed — \(failure.message)"
        }
        if !model.isOnNetwork { return "No network connection" }
        guard let lastSuccess = model.snapshot.lastSuccess else { return "Not connected yet" }
        let prefix = model.isStale ? "Stale — last updated" : "Updated"
        return "\(prefix) \(Format.relative(lastSuccess))"
    }
}

private struct DeviceRow: View {
    @Environment(AppModel.self) private var model
    let device: Device

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: device.deviceStatus.symbolName)
                .foregroundStyle(device.deviceStatus.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.displayName).font(.callout)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.toggleMute(device)
            } label: {
                Image(systemName: model.isMuted(device) ? "bell.slash" : "bell")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(model.isMuted(device) ? "Unmute this device" : "Mute notifications for this device")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var subtitle: String {
        var parts = [device.deviceStatus.label, Device.formatMAC(device.mac)]
        if let modelName = model.snapshot.modelName(for: device) { parts.append(modelName) }
        if let site = model.snapshot.siteName(for: device) { parts.append(site) }
        return parts.joined(separator: " · ")
    }
}
