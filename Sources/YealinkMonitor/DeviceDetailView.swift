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
    @State private var restartRequest: RestartRequest?
    @State private var diagnostics: DeviceDiagnostics?
    @State private var calls: [CallRecord] = []

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
                let accessories = model.accessories(for: device)
                if !accessories.isEmpty {
                    Divider()
                    accessorySection(accessories)
                }
                let alarms = model.alarms(for: device)
                if !alarms.isEmpty {
                    Divider()
                    alarmSection(alarms)
                }
                if !calls.isEmpty {
                    Divider()
                    callSection
                }
                if let diagnostics {
                    Divider()
                    DiagnosticsSection(device: device, diagnostics: diagnostics)
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
        // One runner per device: switching selection should not show the
        // previous phone's ping output under the new phone's name.
        .onAppear { diagnostics = DeviceDiagnostics(model: model) }
        .onChange(of: device.id) { diagnostics = DeviceDiagnostics(model: model) }
        .restartConfirmation($restartRequest)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(device.displayName).font(.title2).bold()
                Spacer()
                Button(model.isMuted(device) ? "Unmute" : "Mute") {
                    model.toggleMute(device)
                }
                Button(model.isArchived(device) ? "Restore" : "Archive") {
                    model.setArchived(!model.isArchived(device), for: [device])
                }
                .help(model.isArchived(device)
                    ? "Put this phone back in the fleet"
                    : "Not in service — keep it out of counts, alerts and bulk actions")
                Button("Restart…") {
                    restartRequest = RestartRequest([device])
                }
                .disabled(model.isRebooting(device) || device.deviceStatus != .online)
                .help(restartHelp)
            }
            HStack(spacing: 8) {
                StatusBadge(status: device.deviceStatus)
                if model.isArchived(device) {
                    Label("Archived", systemImage: "archivebox")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    /// Names the fleet's version when this phone is behind it. Not framed as a
    /// fault: a phone can be deliberately held back, and this app does not push
    /// firmware.
    private var firmwareText: String {
        let version = device.programVersion ?? "—"
        guard model.isBehindFleetFirmware(device),
              let modelId = device.modelId,
              let common = model.snapshot.fleetFirmware[modelId]
        else { return version }
        return "\(version) — most of this model runs \(common)"
    }

    /// An offline phone cannot be restarted: the command goes to YMCS, which
    /// has no way to reach it. Saying so beats a button that reports success and
    /// does nothing.
    private var restartHelp: String {
        switch device.deviceStatus {
        case .online: "Restart this phone through YMCS"
        case .offline: "This phone is offline, so it cannot receive a restart command"
        case .pending: "This phone has never reported in, so it cannot receive a restart command"
        case .unknown: "This phone's status is unknown to YMCS"
        }
    }

    private var facts: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 8) {
            row("MAC", Device.formatMAC(device.mac))
            row("Serial", device.sn ?? "—")
            row("Model", detail?.modelName ?? model.snapshot.modelName(for: device) ?? "—")
            row("Site", detail?.siteName ?? model.snapshot.siteName(for: device) ?? "—")
            row("LAN IP", detail?.lanIp ?? (isLoading ? "…" : "—"))
            row("Firmware", firmwareText)
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
            // Only worth saying about a phone that is up. An offline phone
            // reports its lines as unregistered too, and telling someone that
            // a phone which is down is "reachable" is simply false -- the
            // status above already says what is wrong with it.
            if device.deviceStatus == .online,
               accounts.contains(where: { $0.status?.isHealthy == false })
            {
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

    /// The last week of calls from this phone. A handset that is online around
    /// the clock and sounds bad on every call is a fault the status view cannot
    /// express at all.
    private var callSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent calls").font(.headline)
                Spacer()
                let poor = calls.count { $0.quality?.isPoor ?? false }
                if poor > 0 {
                    Text("\(poor) of \(calls.count) poor or bad")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            ForEach(calls.prefix(8)) { call in
                HStack(spacing: 8) {
                    Circle()
                        .fill(call.quality.tint)
                        .frame(width: 8, height: 8)
                    Text(call.quality?.rawValue ?? "—")
                        .frame(width: 56, alignment: .leading)
                    Text(call.username ?? "—")
                        .lineLimit(1)
                    Spacer()
                    if let mos = call.mos {
                        Text("MOS \(Format.mos(mos))")
                            .foregroundStyle(mos < 3.6 ? Color.orange : .secondary)
                    }
                    Text(Format.callDuration(call.durationSeconds))
                        .foregroundStyle(.secondary)
                    Text(Format.dateTime(call.startDate))
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
    }

    /// Headsets, expansion modules and the like. Worth its own section because a
    /// phone reports itself perfectly healthy while an attached module is dead,
    /// and the device list has no way to show that.
    private func accessorySection(_ accessories: [Accessory]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Accessories").font(.headline)
                Spacer()
                Button("Restart All…") {
                    restartRequest = RestartRequest(accessoriesOn: device, parts: [])
                }
                .font(.callout)
                .disabled(device.deviceStatus != .online)
            }
            ForEach(accessories) { accessory in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: accessory.isProblem ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(accessory.isProblem ? Color.orange : .green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(accessory.displayName)
                        Text(accessorySubtitle(accessory))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Restart…") {
                        restartRequest = RestartRequest(accessoriesOn: device, parts: [accessory])
                    }
                    .font(.caption)
                    .disabled(device.deviceStatus != .online)
                }
                .font(.callout)
            }
            if accessories.contains(where: \.isProblem) {
                Label(
                    "This phone is online but an accessory is not connected, so part of it does not work.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
    }

    private func accessorySubtitle(_ accessory: Accessory) -> String {
        var parts: [String] = []
        switch accessory.connStatus {
        case .online: parts.append("Connected")
        case .offline: parts.append("Not connected")
        case .notReported: parts.append("Never reported")
        case .unknown(let raw): parts.append("Status \(raw)")
        case nil: break
        }
        if let way = accessory.connectWay, !way.isEmpty { parts.append(way) }
        if let version = accessory.programVersion, !version.isEmpty { parts.append(version) }
        if let mac = accessory.mac, !mac.isEmpty { parts.append(Device.formatMAC(mac)) }
        return parts.joined(separator: " · ")
    }

    /// YMCS's own view of what is wrong with this phone. Worth showing next to
    /// our history because the timestamps come from YMCS rather than from
    /// whenever this app happened to poll, and because an alarm can be active on
    /// a phone this app considers online.
    private func alarmSection(_ alarms: [Alarm]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Active alarms").font(.headline)
            ForEach(alarms) { alarm in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: alarm.level?.symbolName ?? "exclamationmark.circle")
                        .foregroundStyle(alarm.level?.tint ?? .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(alarm.event ?? "Alarm")
                        Text(alarmSubtitle(alarm))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .font(.callout)
            }
        }
    }

    private func alarmSubtitle(_ alarm: Alarm) -> String {
        var parts: [String] = []
        if let level = alarm.level { parts.append(level.label) }
        if let first = alarm.firstAlarmDate {
            parts.append("since \(Format.dateTime(first))")
        }
        // Only worth showing when it differs -- a one-shot alarm has both.
        if let last = alarm.lastAlarmDate, last != alarm.firstAlarmDate {
            parts.append("last \(Format.relative(last))")
        }
        return parts.joined(separator: " · ")
    }

    private func historySection(_ entries: [StatusChange]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent changes").font(.headline)
            ForEach(entries.prefix(12)) { change in
                HStack(spacing: 8) {
                    Image(systemName: change.historySymbolName)
                        .foregroundStyle(change.cause == .reboot ? Color.secondary : change.to.tint)
                    Text(change.historyLabel)
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
        // Separate, and deliberately not fatal to the rest of the pane: an
        // enterprise without call quality data should not see an error here.
        calls = (try? await model.recentCalls(for: device))?
            .sorted { ($0.startTime ?? 0) > ($1.startTime ?? 0) } ?? []
    }
}
