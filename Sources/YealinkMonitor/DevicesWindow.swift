import AppKit
import SwiftUI
import UniformTypeIdentifiers
import YMCSKit

let DevicesWindowID = "devices"

/// The full picture: every phone, filterable, with detail on selection.
struct DevicesWindow: View {
    @Environment(AppModel.self) private var model

    @State private var selection = Set<Device.ID>()
    @State private var search = ""
    @State private var scope = Scope.all

    /// What the list is showing. Archived is a scope rather than a status
    /// because it cuts across the real ones -- an archived phone still has an
    /// online/offline status, it just is not part of the fleet.
    private enum Scope: Hashable {
        case all
        case status(DeviceStatus)
        case archived
    }
    @State private var siteFilter: String?
    @State private var sortOrder = [KeyPathComparator(\Device.displayName)]
    @State private var restartRequest: RestartRequest?

    var body: some View {
        NavigationSplitView {
            list
        } detail: {
            if let device = selectedDevices.count == 1 ? selectedDevices.first : nil {
                DeviceDetailView(device: device)
                    .id(device.id)
            } else if selectedDevices.count > 1 {
                ContentUnavailableView(
                    "\(selectedDevices.count) phones selected",
                    systemImage: "square.stack",
                    description: Text("Select a single phone to see its detail, or use Restart to act on all of them.")
                )
            } else {
                ContentUnavailableView(
                    "No phone selected",
                    systemImage: "sidebar.left",
                    description: Text("Choose a phone to see its IP, firmware and SIP lines.")
                )
            }
        }
        .navigationTitle("Phones")
        .toolbar {
            ToolbarItem(placement: .status) {
                Text(statusLine)
                    .font(.callout)
                    .foregroundStyle(model.isStale ? .orange : .secondary)
            }
            ToolbarItem {
                exportMenu
            }
            ToolbarItem {
                restartMenu
            }
            ToolbarItem {
                Button {
                    model.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.snapshot.isPolling)
            }
        }
        .restartConfirmation($restartRequest)
    }

    /// Two scopes, named explicitly. "All Listed" says *listed* rather than
    /// *all* because it obeys the filters above, which is the whole risk.
    private var restartMenu: some View {
        Menu {
            Button("Restart Selected (\(selectedDevices.count))…") {
                restartRequest = RestartRequest(selectedDevices)
            }
            .disabled(selectedDevices.isEmpty)

            Button("Restart All Listed (\(filtered.count))…") {
                restartRequest = RestartRequest(filtered, scope: scopeDescription)
            }
            .disabled(filtered.isEmpty)
        } label: {
            Label("Restart", systemImage: "restart.circle")
        }
    }

    /// Exports what is listed, or just the selection. Same two scopes as the
    /// restart menu, and named the same way, so "All Listed" always means the
    /// filters above are in force.
    private var exportMenu: some View {
        Menu {
            Button("Export All Listed (\(filtered.count))…") {
                export(filtered, scope: scopeDescription)
            }
            .disabled(filtered.isEmpty)

            Button("Export Selected (\(selectedDevices.count))…") {
                export(selectedDevices, scope: "selection")
            }
            .disabled(selectedDevices.isEmpty)
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
    }

    private func export(_ devices: [Device], scope: String) {
        let panel = NSSavePanel()
        panel.title = "Export Phones"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = Self.exportFilename()
        panel.isExtensionHidden = false
        // The CSV is built before the panel returns, so what is written is what
        // was on screen when the user asked, not whatever the next poll brings.
        let data = model.exportCSV(devices)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func exportFilename() -> String {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmm"
        return "phones-\(stamp.string(from: Date())).csv"
    }

    private func archiveTitle(for devices: [Device], archiving: Bool) -> String {
        let verb = archiving ? "Archive" : "Restore"
        return devices.count == 1 ? verb : "\(verb) \(devices.count) Phones"
    }

    private var selectedDevices: [Device] {
        // Ordered as listed, so the confirmation names them in the order the
        // user sees them.
        filtered.filter { selection.contains($0.id) }
    }

    /// The current filters in words, for the confirmation dialog.
    private var scopeDescription: String {
        var parts: [String] = []
        switch scope {
        case .all: break
        case .status(let status): parts.append("status \(status.label.lowercased())")
        case .archived: parts.append("archived")
        }
        if let siteFilter {
            parts.append("site \(model.snapshot.siteNames[siteFilter] ?? siteFilter)")
        }
        let query = search.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty { parts.append("search “\(query)”") }
        return parts.isEmpty ? "every phone" : parts.joined(separator: ", ")
    }

    private var list: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            Table(filtered, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("") { device in
                    Image(systemName: device.deviceStatus.symbolName)
                        .foregroundStyle(device.deviceStatus.tint)
                        .help(device.deviceStatus.label)
                }
                .width(20)

                TableColumn("Name", value: \.displayName) { device in
                    HStack(spacing: 4) {
                        Text(device.displayName)
                        if model.isMuted(device) {
                            Image(systemName: "bell.slash")
                                .foregroundStyle(.secondary)
                                .help("Notifications muted")
                        }
                        if model.accessories(for: device).contains(where: \.isProblem) {
                            Image(systemName: "cable.connector.slash")
                                .foregroundStyle(.orange)
                                .help("An accessory on this phone is not connected")
                        }
                        if model.isArchived(device) {
                            Image(systemName: "archivebox")
                                .foregroundStyle(.secondary)
                                .help("Archived — not counted or alerted on")
                        }
                        let alarms = model.alarms(for: device)
                        if let worst = alarms.first {
                            Image(systemName: worst.level?.symbolName ?? "exclamationmark.circle")
                                .foregroundStyle(worst.level?.tint ?? .secondary)
                                .help(alarms.compactMap(\.event).joined(separator: ", "))
                        }
                    }
                }

                TableColumn("MAC") { Text(Device.formatMAC($0.mac)).monospaced() }

                TableColumn("Model") { device in
                    Text(model.snapshot.modelName(for: device) ?? "—")
                }

                TableColumn("Site") { device in
                    Text(model.snapshot.siteName(for: device) ?? "—")
                }

                // Blank until the detail sweep reaches this phone: the device
                // list itself carries no IP address.
                TableColumn("LAN IP") { device in
                    Text(model.lanIP(for: device) ?? "—")
                        .monospaced()
                        .foregroundStyle(model.lanIP(for: device) == nil ? .secondary : .primary)
                }

                TableColumn("Firmware") { device in
                    HStack(spacing: 4) {
                        Text(device.programVersion ?? "—")
                        if model.isBehindFleetFirmware(device) {
                            Image(systemName: "arrow.down.circle")
                                .foregroundStyle(.secondary)
                                .help("Older than the build most of this model is running")
                        }
                    }
                }
            }
            .contextMenu(forSelectionType: Device.ID.self) { ids in
                let devices = model.snapshot.devices.filter { ids.contains($0.id) }
                if devices.count == 1, let device = devices.first {
                    Button(model.isMuted(device) ? "Unmute" : "Mute Notifications") {
                        model.toggleMute(device)
                    }
                    Button("Copy MAC Address") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Device.formatMAC(device.mac), forType: .string)
                    }
                }
                if !devices.isEmpty {
                    Divider()
                    let archiving = !devices.allSatisfy { model.isArchived($0) }
                    Button(archiveTitle(for: devices, archiving: archiving)) {
                        model.setArchived(archiving, for: devices)
                    }
                }
                if !devices.isEmpty {
                    Divider()
                    Button(devices.count == 1 ? "Restart…" : "Restart \(devices.count) Phones…") {
                        restartRequest = RestartRequest(devices)
                    }
                }
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Name or MAC")
        .navigationSplitViewColumnWidth(min: 520, ideal: 760)
    }

    private var filterBar: some View {
        HStack(spacing: 12) {
            Picker("Status", selection: $scope) {
                // Counts are of phones in service. Archived ones are counted
                // only under their own entry.
                Text("All (\(model.activeDevices.count))").tag(Scope.all)
                Text("Online (\(count(.online)))").tag(Scope.status(.online))
                Text("Offline (\(count(.offline)))").tag(Scope.status(.offline))
                Text("Never reported (\(count(.pending)))").tag(Scope.status(.pending))
                if !model.archivedDevices.isEmpty {
                    Divider()
                    Text("Archived (\(model.archivedDevices.count))").tag(Scope.archived)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()

            if !model.snapshot.siteNames.isEmpty {
                Picker("Site", selection: $siteFilter) {
                    Text("All sites").tag(String?.none)
                    ForEach(sortedSites, id: \.0) { id, name in
                        Text(name).tag(String?.some(id))
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }

            Spacer()
        }
        .padding(8)
    }

    private var sortedSites: [(String, String)] {
        model.snapshot.siteNames
            .map { ($0.key, $0.value) }
            .sorted { $0.1.localizedStandardCompare($1.1) == .orderedAscending }
    }

    private func count(_ status: DeviceStatus) -> Int {
        model.activeDevices.count { $0.deviceStatus == status }
    }

    private var filtered: [Device] {
        // Archived phones are out of every other scope, so a bulk restart or an
        // export of "All Listed" cannot reach the spare in the cupboard.
        var devices: [Device]
        switch scope {
        case .all: devices = model.activeDevices
        case .status(let status): devices = model.activeDevices.filter { $0.deviceStatus == status }
        case .archived: devices = model.archivedDevices
        }
        if let siteFilter {
            devices = devices.filter { $0.siteId == siteFilter }
        }
        let query = search.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            // Match the bare MAC too, so pasting "001565bbb1a9" works as well as
            // the colon-separated form shown in the table.
            let bare = query.filter(\.isHexDigit).lowercased()
            devices = devices.filter { device in
                device.displayName.localizedCaseInsensitiveContains(query)
                    || (!bare.isEmpty && device.mac.lowercased().contains(bare))
            }
        }
        return devices.sorted(using: sortOrder)
    }

    private var statusLine: String {
        guard let lastSuccess = model.snapshot.lastSuccess else { return "Not connected" }
        let prefix = model.isStale ? "Stale — last updated" : "Updated"
        return "\(prefix) \(Format.relative(lastSuccess))"
    }
}
