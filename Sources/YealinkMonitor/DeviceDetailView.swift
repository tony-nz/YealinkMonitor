import SwiftUI
import YMCSKit

/// Detail is fetched per selection rather than for every device in the list:
/// one request when the user actually looks, instead of one per phone per poll.
struct DeviceDetailView: View {
    @Environment(AppModel.self) private var model
    let device: Device

    @State private var detail: DeviceDetail?
    @State private var error: String?
    @State private var isLoading = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                heading
                Divider()
                facts
                if let accounts = detail?.accounts, !accounts.isEmpty {
                    Divider()
                    lines(accounts)
                }
                let entries = model.history.entries(forDeviceID: device.id)
                if !entries.isEmpty {
                    Divider()
                    historySection(entries)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: device.id) { await load() }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(device.displayName).font(.title2).bold()
                Spacer()
                Button(model.isMuted(device) ? "Unmute" : "Mute") {
                    model.toggleMute(device)
                }
            }
            StatusBadge(status: device.deviceStatus)
            if let error {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var facts: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 8) {
            row("MAC", Device.formatMAC(device.mac))
            row("Serial", device.sn ?? "—")
            row("Model", detail?.modelName ?? model.snapshot.modelName(for: device) ?? "—")
            row("Site", detail?.siteName ?? model.snapshot.siteName(for: device) ?? "—")
            row("LAN IP", detail?.lanIp ?? (isLoading ? "…" : "—"))
            row("Firmware", device.programVersion ?? "—")
            // How stale YMCS's own view is -- distinct from how stale this
            // app's copy of YMCS is.
            row("Last reported", detail.map { Format.dateTime($0.lastReportDate) } ?? (isLoading ? "…" : "—"))
        }
    }

    private func lines(_ accounts: [ReportAccount]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SIP lines").font(.headline)
            ForEach(Array(accounts.enumerated()), id: \.offset) { _, account in
                HStack(spacing: 8) {
                    Text("Line \(account.lineId.map(String.init) ?? "?")")
                        .frame(width: 60, alignment: .leading)
                    Text(account.username ?? account.registerName ?? "—")
                    Spacer()
                    if let status = account.status {
                        Text(status.label)
                            .font(.caption)
                            .foregroundStyle(status.tint)
                    }
                }
                .font(.callout)
            }
            if accounts.contains(where: { $0.status?.isHealthy == false }) {
                // The failure mode the device status alone hides.
                Label(
                    "This phone is reachable but has a line that is not registered, so it cannot take calls on it.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
    }

    private func historySection(_ entries: [StatusChange]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent changes").font(.headline)
            ForEach(entries.prefix(12)) { change in
                HStack(spacing: 8) {
                    Image(systemName: change.to.symbolName)
                        .foregroundStyle(change.to.tint)
                    Text(change.to.label)
                    Spacer()
                    Text(Format.dateTime(change.at))
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            Text(value).textSelection(.enabled)
        }
        .font(.callout)
    }

    private func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            detail = try await model.detail(for: device)
        } catch {
            detail = nil
            // Detail is supplementary; the list data above stays valid.
            self.error = (error as? YMCSError)?.errorDescription ?? error.localizedDescription
        }
    }
}
