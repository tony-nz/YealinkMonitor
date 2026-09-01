import SwiftUI
import YMCSKit

let ActivityWindowID = "activity"

/// Two things YMCS knows that the device list does not: how calls actually
/// sounded, and what anyone changed.
///
/// Both are fetched on demand rather than polled. Neither feeds an alert, and
/// polling them would spend the enterprise's request budget on data nobody is
/// looking at.
struct ActivityWindow: View {
    enum Tab: String, CaseIterable, Identifiable {
        case quality
        case log

        var id: String { rawValue }

        var title: String {
            switch self {
            case .quality: "Call Quality"
            case .log: "Operation Log"
            }
        }

        var symbolName: String {
            switch self {
            case .quality: "waveform"
            case .log: "list.bullet.rectangle"
            }
        }
    }

    @Environment(AppModel.self) private var model
    @State private var tab = Tab.quality
    @State private var store: ActivityStore?
    @State private var days = 7

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { tab in
                    Label(tab.title, systemImage: tab.symbolName).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)

            Divider()

            if let store {
                switch tab {
                case .quality: QualityTab(store: store, days: $days)
                case .log: LogTab(store: store, days: $days)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Activity")
        .onAppear { if store == nil { store = ActivityStore(model: model) } }
    }
}

/// Fetches and holds the two on-demand datasets.
@MainActor
@Observable
final class ActivityStore {
    private(set) var calls: [CallRecord] = []
    private(set) var statistics: QualityStatistics?
    private(set) var logs: [OperationLog] = []
    private(set) var isLoading = false
    private(set) var error: String?

    private let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    func loadQuality(days: Int) async {
        if model.isDemo {
            calls = DemoFleet.calls()
            statistics = DemoFleet.statistics()
            return
        }
        await load { client, since, now in
            async let records = client.listCalls(limit: 500, since: since, until: now)
            async let stats = client.callQualityStatistics(since: since, until: now)
            let (page, summary) = try await (records, stats)
            self.calls = page.items.sorted { ($0.startTime ?? 0) > ($1.startTime ?? 0) }
            self.statistics = summary
        } days: { days }
    }

    func loadLogs(days: Int) async {
        if model.isDemo {
            logs = DemoFleet.logs()
            return
        }
        await load { client, since, now in
            let page = try await client.listOperationLogs(limit: 500, since: since, until: now)
            self.logs = page.items.sorted { ($0.createTime ?? 0) > ($1.createTime ?? 0) }
        } days: { days }
    }

    private func load(
        _ work: (YMCSClient, Date, Date) async throws -> Void,
        days: () -> Int
    ) async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        let now = Date()
        let since = now.addingTimeInterval(-Double(days()) * 86_400)
        do {
            try await work(model.makeClient(), since, now)
        } catch {
            self.error = (error as? YMCSError)?.errorDescription ?? error.localizedDescription
        }
    }
}

private struct QualityTab: View {
    @Bindable var store: ActivityStore
    @Binding var days: Int

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                PeriodPicker(days: $days)
                if let statistics = store.statistics {
                    summary(statistics)
                }
                Spacer()
                if store.isLoading { ProgressView().controlSize(.small) }
            }
            .padding(12)

            Divider()

            if let error = store.error {
                ContentUnavailableView("Could not load call quality", systemImage: "waveform.slash", description: Text(error))
            } else if store.calls.isEmpty && !store.isLoading {
                ContentUnavailableView(
                    "No calls in this period",
                    systemImage: "waveform",
                    description: Text("YMCS only scores calls made through accounts it manages.")
                )
            } else {
                Table(store.calls) {
                    TableColumn("Quality") { call in
                        Label {
                            Text(call.quality?.rawValue ?? "—")
                        } icon: {
                            Circle()
                                .fill(call.quality.tint)
                                .frame(width: 8, height: 8)
                        }
                    }
                    .width(90)
                    TableColumn("Phone") { Text($0.deviceName ?? $0.mac.map(Device.formatMAC) ?? "—") }
                    // Not caller/callee: the API documents both and returns
                    // neither, so those columns could only ever be empty.
                    TableColumn("Account") { Text($0.username ?? "—") }
                    TableColumn("MOS") { call in
                        Text(Format.mos(call.mos))
                            .foregroundStyle(call.mos.map { $0 < 3.6 ? Color.orange : .primary } ?? .secondary)
                            .help("Mean Opinion Score, 1-5. Below about 3.6 is audibly poor.")
                    }
                    .width(60)
                    TableColumn("Duration") { Text(Format.callDuration($0.durationSeconds)) }
                    TableColumn("Started") { Text(Format.dateTime($0.startDate)) }
                    TableColumn("Site") { Text($0.siteName ?? "—") }
                }
            }
        }
        .task(id: days) { await store.loadQuality(days: days) }
    }

    /// The headline number: a fleet that is always online and 12% bad is a
    /// fleet with a problem the offline count will never show.
    private func summary(_ statistics: QualityStatistics) -> some View {
        HStack(spacing: 16) {
            LabeledContent("Calls", value: "\(statistics.total)")
            if let bad = statistics.badPercentage {
                LabeledContent("Poor or bad") {
                    Text(bad.formatted(.number.precision(.fractionLength(0...1))) + "%")
                        .foregroundStyle(bad >= 5 ? .orange : .primary)
                }
            }
        }
        .font(.callout)
        .fixedSize()
    }
}

private struct LogTab: View {
    @Bindable var store: ActivityStore
    @Binding var days: Int
    @State private var search = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                PeriodPicker(days: $days)
                TextField("Filter", text: $search, prompt: Text("MAC, operator or action"))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                Spacer()
                if store.isLoading { ProgressView().controlSize(.small) }
            }
            .padding(12)

            Divider()

            if let error = store.error {
                ContentUnavailableView("Could not load the log", systemImage: "list.bullet.rectangle", description: Text(error))
            } else if filtered.isEmpty && !store.isLoading {
                ContentUnavailableView("Nothing in this period", systemImage: "list.bullet.rectangle")
            } else {
                Table(filtered) {
                    TableColumn("When") { Text(Format.dateTime($0.date)) }
                    TableColumn("Action") { Text(OperationLog.readable($0.operationType)) }
                    TableColumn("Object") { log in
                        // Usually a MAC, occasionally a name.
                        Text(log.operationObject.map { $0.count == 12 ? Device.formatMAC($0) : $0 } ?? "—")
                            .monospaced()
                    }
                    TableColumn("Who") { Text($0.operator ?? "—") }
                    TableColumn("From") { Text($0.ip ?? "—") }
                    TableColumn("Result") { Text($0.result ?? "—") }
                }
            }
        }
        .task(id: days) { await store.loadLogs(days: days) }
    }

    private var filtered: [OperationLog] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return store.logs }
        let bare = query.filter(\.isHexDigit).lowercased()
        return store.logs.filter { log in
            OperationLog.readable(log.operationType).localizedCaseInsensitiveContains(query)
                || (log.operator ?? "").localizedCaseInsensitiveContains(query)
                || (!bare.isEmpty && (log.operationObject ?? "").lowercased().contains(bare))
        }
    }
}

private struct PeriodPicker: View {
    @Binding var days: Int

    var body: some View {
        Picker("Period", selection: $days) {
            Text("Last 24 hours").tag(1)
            Text("Last 7 days").tag(7)
            Text("Last 30 days").tag(30)
        }
        .pickerStyle(.menu)
        .fixedSize()
    }
}
