import SwiftUI
import YMCSKit

let DevicesWindowID = "devices"

/// The full picture: every phone, filterable, with detail on selection.
struct DevicesWindow: View {
    @Environment(AppModel.self) private var model

    @State private var selection: Device.ID?
    @State private var search = ""
    @State private var statusFilter: DeviceStatus?
    @State private var siteFilter: String?
    @State private var sortOrder = [KeyPathComparator(\Device.displayName)]

    var body: some View {
        NavigationSplitView {
            list
        } detail: {
            if let selection, let device = model.snapshot.devices.first(where: { $0.id == selection }) {
                DeviceDetailView(device: device)
                    .id(device.id)
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
                Button {
                    model.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.snapshot.isPolling)
            }
        }
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
                    }
                }

                TableColumn("MAC") { Text(Device.formatMAC($0.mac)).monospaced() }

                TableColumn("Model") { device in
                    Text(model.snapshot.modelName(for: device) ?? "—")
                }

                TableColumn("Site") { device in
                    Text(model.snapshot.siteName(for: device) ?? "—")
                }

                TableColumn("Firmware") { Text($0.programVersion ?? "—") }
            }
            .contextMenu(forSelectionType: Device.ID.self) { ids in
                if let id = ids.first,
                   let device = model.snapshot.devices.first(where: { $0.id == id }) {
                    Button(model.isMuted(device) ? "Unmute" : "Mute Notifications") {
                        model.toggleMute(device)
                    }
                    Button("Copy MAC Address") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Device.formatMAC(device.mac), forType: .string)
                    }
                }
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Name or MAC")
        .navigationSplitViewColumnWidth(min: 520, ideal: 760)
    }

    private var filterBar: some View {
        HStack(spacing: 12) {
            Picker("Status", selection: $statusFilter) {
                Text("All (\(model.snapshot.devices.count))").tag(DeviceStatus?.none)
                Text("Online (\(model.snapshot.onlineCount))").tag(DeviceStatus?.some(.online))
                Text("Offline (\(model.snapshot.offlineCount))").tag(DeviceStatus?.some(.offline))
                Text("Never reported (\(model.snapshot.pendingCount))").tag(DeviceStatus?.some(.pending))
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

    private var filtered: [Device] {
        var devices = model.snapshot.devices
        if let statusFilter {
            devices = devices.filter { $0.deviceStatus == statusFilter }
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
