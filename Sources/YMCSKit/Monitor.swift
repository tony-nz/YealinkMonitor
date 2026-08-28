import Foundation

public struct MonitorFailure: Sendable, Hashable {
    public let message: String
    /// The credentials or region are wrong; polling harder will not help and
    /// the UI should send the user to Settings.
    public let needsAttention: Bool
    public let retryAfter: Duration?

    init(_ error: any Error) {
        if let error = error as? YMCSError {
            message = error.errorDescription ?? "\(error)"
            switch error {
            case .authenticationFailed, .forbidden, .notConfigured:
                needsAttention = true
                retryAfter = nil
            case .rateLimited(let retryAfter):
                needsAttention = false
                self.retryAfter = retryAfter
            default:
                needsAttention = false
                retryAfter = nil
            }
        } else {
            message = error.localizedDescription
            needsAttention = false
            retryAfter = nil
        }
    }
}

/// Everything the UI needs to render, in one value.
public struct MonitorSnapshot: Sendable, Equatable {
    public var devices: [Device] = []
    public var modelNames: [String: String] = [:]
    /// Model id -> device type. `listDevices` does not report a device's type,
    /// but `models` is queried per type, so the model lookup answers it.
    public var modelTypes: [String: DeviceType] = [:]
    public var siteNames: [String: String] = [:]
    /// Active alarms only -- YMCS returns solved and ignored ones in the same
    /// list and offers no status filter, so they are dropped on the way in.
    public var alarms: [Alarm] = []
    /// What YMCS reported as the total alarm count, before the active filter and
    /// before `allAlarms` stopped paging. Non-nil and larger than `alarms.count`
    /// means the list on screen is a prefix.
    public var alarmTotal: Int64?
    /// Accessories keyed by the device they are attached to.
    public var accessories: [String: [Accessory]] = [:]
    /// Per-device detail, keyed by device id.
    ///
    /// `listDevices` does not return a LAN IP, a serial or the SIP line state --
    /// only `GET /v2/dm/devices/{id}` does, one request per phone. So this is
    /// filled by a slow background sweep rather than by the polling loop.
    public var details: [String: DeviceDetail] = [:]
    /// When device data was last successfully read. The UI must date-stamp what
    /// it shows against this, never against "now".
    public var lastSuccess: Date?
    public var lastAttempt: Date?
    public var failure: MonitorFailure?
    public var isPolling: Bool = false

    public init() {}

    public var onlineCount: Int { devices.count { $0.deviceStatus == .online } }
    public var offlineCount: Int { devices.count { $0.deviceStatus == .offline } }
    public var pendingCount: Int { devices.count { $0.deviceStatus == .pending } }

    /// Devices needing attention, worst first, then by name.
    public var problems: [Device] {
        devices
            .filter { $0.deviceStatus != .online }
            .sorted { lhs, rhs in
                if lhs.deviceStatus != rhs.deviceStatus {
                    return lhs.deviceStatus == .offline
                }
                return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }
    }

    public func modelName(for device: Device) -> String? {
        device.modelId.flatMap { modelNames[$0] }
    }

    /// The device's type, or nil when its model is not in the lookup yet.
    /// Needed by any endpoint that takes `deviceType`, which the device list
    /// itself never returns.
    public func deviceType(for device: Device) -> DeviceType? {
        device.modelId.flatMap { modelTypes[$0] }
    }

    public func siteName(for device: Device) -> String? {
        device.siteId.flatMap { siteNames[$0] }
    }

    /// Alarms YMCS has raised against this device, newest first.
    ///
    /// Matched on MAC rather than device id: `listAlarms` does not return one.
    public func alarms(for device: Device) -> [Alarm] {
        let mac = Device.normalizeMAC(device.mac)
        return alarms
            .filter { $0.normalizedMAC == mac }
            .sorted { ($0.lastAlarmTime ?? $0.firstAlarmTime ?? 0) > ($1.lastAlarmTime ?? $1.firstAlarmTime ?? 0) }
    }

    /// The firmware version most of this model is running.
    ///
    /// The most common version rather than the highest: one phone on a beta
    /// build should not make the whole fleet look out of date. Ties break
    /// towards the newer version.
    public var fleetFirmware: [String: String] {
        var byModel: [String: [String: Int]] = [:]
        for device in devices {
            guard let modelId = device.modelId,
                  let version = device.programVersion, !version.isEmpty
            else { continue }
            byModel[modelId, default: [:]][version, default: 0] += 1
        }
        return byModel.compactMapValues { counts in
            counts.max { lhs, rhs in
                lhs.value == rhs.value
                    ? Device.isFirmware(lhs.key, olderThan: rhs.key)
                    : lhs.value < rhs.value
            }?.key
        }
    }

    /// True when this phone is running an older build than the rest of its
    /// model. Not an alert -- a phone can be deliberately held back -- but it is
    /// the first thing to check when one handset behaves differently.
    public func isBehindFleetFirmware(_ device: Device, reference: [String: String]? = nil) -> Bool {
        guard let modelId = device.modelId,
              let version = device.programVersion,
              let common = (reference ?? fleetFirmware)[modelId]
        else { return false }
        return Device.isFirmware(version, olderThan: common)
    }

    public func accessories(for device: Device) -> [Accessory] {
        accessories[device.id] ?? []
    }

    public func detail(for device: Device) -> DeviceDetail? {
        details[device.id]
    }

    /// The device's LAN IP, once the detail sweep has reached it.
    public func lanIP(for device: Device) -> String? {
        details[device.id]?.lanIp
    }

    /// Devices whose accessories are attached but not working. A phone with a
    /// dead expansion module reports itself perfectly healthy.
    public var devicesWithAccessoryProblems: [Device] {
        devices.filter { device in
            accessories(for: device).contains(where: \.isProblem)
        }
    }

    /// Devices with at least one active alarm, worst level first.
    public var alarmedDeviceCount: Int {
        Set(alarms.compactMap(\.normalizedMAC)).count
    }

    /// True when the data on screen is too old to be presented as current.
    /// Stale is a distinct state from offline: the phones may be perfectly
    /// healthy and it is this app that has lost contact.
    public func isStale(now: Date = Date(), tolerance: TimeInterval) -> Bool {
        guard let lastSuccess else { return true }
        return now.timeIntervalSince(lastSuccess) > tolerance
    }
}

/// Polls YMCS and publishes snapshots.
///
/// YMCS can push events instead (Event Subscription, in the console under
/// System > Integration > API), but that needs a publicly reachable URL to
/// deliver to, so polling is the only option available to a desktop app.
///
/// The loop is built around the enterprise-wide 50 req/s budget being shared
/// with whatever else uses the same credentials, so it stays cheap:
///
///   - every `heartbeat`, one request for the offline device *count*
///   - the full device list only when that count moved, when `fullRefresh` has
///     elapsed, or when the user asks
///
/// For a 100-phone fleet that is about 1 request/minute at rest, rather than
/// one request per phone.
public actor Monitor {
    public struct Configuration: Sendable {
        /// How often the cheap count is checked.
        public var heartbeat: Duration = .seconds(60)
        /// Upper bound on how long a change can hide behind an unchanged count.
        public var fullRefresh: Duration = .seconds(600)
        /// How often model/site name lookups are refreshed.
        public var lookupRefresh: Duration = .seconds(3600)
        /// How often the alarm list is refreshed. Slower than the heartbeat on
        /// purpose: alarms restate what the device list already shows, and this
        /// costs a request per 500 alarms.
        public var alarmRefresh: Duration = .seconds(300)
        /// How often accessories are re-read. Costs one request per 100 devices,
        /// so it runs well below the heartbeat.
        public var accessoryRefresh: Duration = .seconds(900)
        /// How often per-device detail is re-read.
        ///
        /// This one costs a request *per phone*, so it is the most expensive
        /// thing here and runs the least often. The rate limiter paces it, and
        /// a failure for one phone does not affect the others.
        public var detailRefresh: Duration = .seconds(1800)
        /// How many detail requests may be in flight at once.
        public var detailConcurrency: Int = 4
        /// Consecutive polls required to confirm a device has gone offline.
        public var confirmations: Int = 2
        /// Restrict monitoring to one device type, or nil for all.
        public var deviceType: DeviceType? = nil

        public init() {}

        /// Data older than this is shown as stale rather than current.
        public var staleTolerance: TimeInterval {
            Double(heartbeat.components.seconds) * 3
        }
    }

    private let client: YMCSClient
    private let now: @Sendable () -> Date
    public private(set) var configuration: Configuration

    private var snapshot = MonitorSnapshot()
    private var detector: TransitionDetector
    private var lastOfflineCount: Int64?
    private var lastFullRefresh: Date?
    private var lastLookupRefresh: Date?
    private var lastAlarmRefresh: Date?
    private var lastAccessoryRefresh: Date?
    private var lastDetailRefresh: Date?
    private var runTask: Task<Void, Never>?
    private var suppressions: [String: Suppression] = [:]

    /// A device this app has just rebooted, and what it looked like beforehand.
    private struct Suppression {
        let until: Date
        let statusBefore: DeviceStatus
    }

    private let snapshotBroadcaster = Broadcaster<MonitorSnapshot>(bufferingPolicy: .bufferingNewest(1))
    private let changeBroadcaster = Broadcaster<StatusChange>()

    public init(
        client: YMCSClient,
        configuration: Configuration = Configuration(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.client = client
        self.configuration = configuration
        self.now = now
        self.detector = TransitionDetector(confirmations: configuration.confirmations)
    }

    /// Latest snapshots. Each caller gets an independent stream, and only the
    /// newest value is buffered: a UI that falls behind wants the current
    /// state, not a backlog of old ones.
    public nonisolated var snapshots: AsyncStream<MonitorSnapshot> { snapshotBroadcaster.subscribe() }

    /// Confirmed status changes, for notifications and history. Independent per
    /// caller, and nothing is dropped.
    public nonisolated var changes: AsyncStream<StatusChange> { changeBroadcaster.subscribe() }

    public var current: MonitorSnapshot { snapshot }

    public func update(configuration: Configuration) {
        self.configuration = configuration
        detector = TransitionDetector(confirmations: configuration.confirmations)
    }

    /// Drops all cached state, e.g. after the credentials or region change.
    public func reset() {
        snapshot = MonitorSnapshot()
        detector.reset()
        lastOfflineCount = nil
        lastFullRefresh = nil
        lastLookupRefresh = nil
        lastAlarmRefresh = nil
        lastAccessoryRefresh = nil
        lastDetailRefresh = nil
        suppressions = [:]
        publish()
    }

    // MARK: - Device control

    /// Reboots devices and stops the resulting drop being reported as an outage.
    ///
    /// The suppression window is not cosmetic. A rebooted phone disappears for a
    /// minute or two, which the transition detector will confirm as a regression
    /// and alert on; a scheduled overnight reboot of forty phones would
    /// otherwise generate forty outage alerts and forty recovery alerts, all of
    /// them noise, and would train the user to ignore the app.
    ///
    /// Changes inside the window are still emitted -- attributed to `.reboot`,
    /// so history records what happened -- and the alerting layer is what skips
    /// them. If a phone has not returned when the window closes, that is a real
    /// failure and `expireSuppressions` raises it.
    ///
    /// Devices YMCS reported an error for are not suppressed: nothing was done
    /// to them, so anything that happens to them next is genuine.
    @discardableResult
    public func reboot(
        deviceIDs: [String],
        settlingWindow: Duration = .seconds(600)
    ) async throws -> RebootResult {
        // The endpoint needs a deviceType and `listDevices` does not return one,
        // so it is recovered from the model lookup. An unrecognised model falls
        // back to phone: this app monitors phones, and a wrong type is refused
        // by the server rather than rebooting the wrong device.
        let byID = Dictionary(snapshot.devices.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let grouped = Dictionary(grouping: deviceIDs) { id in
            byID[id].flatMap { snapshot.deviceType(for: $0) } ?? .phone
        }

        var result = RebootResult.empty
        var attempted: [String] = []
        var thrown: (any Error)?
        var unattempted: [String] = []

        for (type, ids) in grouped.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            if thrown != nil {
                unattempted.append(contentsOf: ids)
                continue
            }
            do {
                result = result.merging(try await client.rebootDevices(ids: ids, deviceType: type))
                attempted.append(contentsOf: ids)
            } catch {
                thrown = error
                unattempted.append(contentsOf: ids)
            }
        }

        // Nothing got through: the caller wants the real error, not a result
        // object full of zeroes.
        if let thrown, attempted.isEmpty { throw thrown }
        // Something got through. Folding the failure into the result rather than
        // throwing keeps the successes visible -- throwing here would report a
        // batch that half worked as if it had done nothing.
        if let thrown {
            let message = (thrown as? YMCSError)?.errorDescription ?? thrown.localizedDescription
            result = result.merging(
                RebootResult(
                    total: unattempted.count,
                    successCount: 0,
                    failureCount: unattempted.count,
                    errors: unattempted.map { OpError(field: $0, msg: message) }
                )
            )
        }

        let failed = Set((result.errors ?? []).compactMap(\.field))
        let deadline = now().addingTimeInterval(Double(settlingWindow.components.seconds))
        let statuses = Dictionary(
            snapshot.devices.map { ($0.id, $0.deviceStatus) },
            uniquingKeysWith: { first, _ in first }
        )
        for id in attempted where !failed.contains(id) {
            suppressions[id] = Suppression(
                until: deadline,
                // Absent from the snapshot means this app has never seen it, so
                // treat it as pending: any later status is then a real change.
                statusBefore: statuses[id] ?? .pending
            )
        }
        return result
    }

    /// Devices currently inside a post-reboot settling window.
    public var settlingDeviceIDs: Set<String> {
        let moment = now()
        return Set(suppressions.filter { $0.value.until > moment }.keys)
    }

    // MARK: - Loop

    public func start() {
        guard runTask == nil else { return }
        runTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.poll()
                let interval = await self.nextInterval()
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
            }
        }
    }

    public func stop() {
        runTask?.cancel()
        runTask = nil
        snapshot.isPolling = false
        publish()
    }

    public var isRunning: Bool { runTask != nil }

    /// Polls immediately, bypassing the heartbeat shortcut. Used by the refresh
    /// button and on wake from sleep, where the cached view is certainly stale.
    public func refreshNow() async {
        await poll(force: true)
    }

    /// Honours a 429 cooldown, so the loop does not keep hammering a server
    /// that has already told it to back off.
    private func nextInterval() async -> Duration {
        if let cooldown = await client.currentCooldown() {
            return max(cooldown, configuration.heartbeat)
        }
        return configuration.heartbeat
    }

    // MARK: - Polling

    public func poll(force: Bool = false) async {
        snapshot.isPolling = true
        snapshot.lastAttempt = now()
        publish()
        defer {
            snapshot.isPolling = false
            publish()
        }

        do {
            if force || shouldFullRefresh() {
                try await performFullRefresh()
            } else {
                let offline = try await client.deviceCount(
                    status: .offline,
                    type: configuration.deviceType
                )
                if offline != lastOfflineCount {
                    try await performFullRefresh()
                } else {
                    // Nothing moved. Treat the heartbeat as a successful read:
                    // the data on screen is confirmed current, not merely old.
                    snapshot.lastSuccess = now()
                    snapshot.failure = nil
                }
            }
        } catch {
            // The previous device list is kept on screen deliberately. Wiping it
            // on a transient network error would show "0 phones" and look far
            // more alarming than the truth.
            snapshot.failure = MonitorFailure(error)
        }
    }

    private func shouldFullRefresh() -> Bool {
        // A device mid-debounce needs to be seen on every poll to accumulate
        // confirmations, and the offline count cannot show that.
        if detector.hasPendingCandidates { return true }
        // Likewise a phone that is mid-reboot: the offline count going down
        // again does not say *which* device came back, and the settling window
        // has to close against real data.
        if !suppressions.isEmpty { return true }
        guard let lastFullRefresh else { return true }
        let elapsed = now().timeIntervalSince(lastFullRefresh)
        return elapsed >= Double(configuration.fullRefresh.components.seconds)
    }

    private func performFullRefresh() async throws {
        let filter = configuration.deviceType.map { DeviceFilter(deviceType: $0) }
        let devices = try await client.allDevices(filter: filter)

        snapshot.devices = devices.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
        snapshot.lastSuccess = now()
        snapshot.failure = nil
        lastFullRefresh = now()
        lastOfflineCount = Int64(devices.count { $0.deviceStatus == .offline })

        let moment = now()
        for change in detector.ingest(devices, at: moment) {
            let isSettling = suppressions[change.device.id].map { $0.until > moment } ?? false
            changeBroadcaster.yield(isSettling ? change.attributed(to: .reboot) : change)
        }
        expireSuppressions(devices: devices, at: moment)

        // Publish the device list before the supplementary sweeps rather than
        // after. The detail sweep costs a request per phone, so waiting for it
        // would leave the window empty for seconds on a small fleet and minutes
        // on a large one, for data none of it needs to draw the first screen.
        publish()

        await refreshLookupsIfNeeded()
        await refreshAlarmsIfNeeded()
        await refreshAccessoriesIfNeeded(devices: devices)
        await refreshDetailsIfNeeded(devices: devices)
    }

    /// Fills in what the device list leaves out: LAN IP, serial, SIP line state.
    ///
    /// One request per phone, so it runs on its own slow schedule and a few at a
    /// time. Details for phones that have since been removed are dropped, and a
    /// phone whose request fails keeps whatever was known before rather than
    /// blanking out.
    private func refreshDetailsIfNeeded(devices: [Device]) async {
        if let lastDetailRefresh,
           now().timeIntervalSince(lastDetailRefresh) < Double(configuration.detailRefresh.components.seconds) {
            return
        }
        guard !devices.isEmpty else { return }
        lastDetailRefresh = now()

        let ids = devices.map(\.id)
        let limit = max(1, configuration.detailConcurrency)
        var fetched: [String: DeviceDetail] = [:]

        await withTaskGroup(of: DeviceDetail?.self) { [client] group in
            var next = 0
            func addTask() {
                guard next < ids.count else { return }
                let id = ids[next]
                next += 1
                group.addTask { try? await client.device(id: id) }
            }
            for _ in 0..<min(limit, ids.count) { addTask() }

            while let result = await group.next() {
                if let result { fetched[result.id] = result }
                addTask()
            }
        }

        // Keep anything this sweep failed to refresh, but drop devices that are
        // no longer in the fleet at all.
        let known = Set(ids)
        var merged = snapshot.details.filter { known.contains($0.key) }
        merged.merge(fetched) { _, new in new }
        snapshot.details = merged
        publish()
    }

    /// Supplementary like the alarms: a failure leaves the previous accessory
    /// list in place and never fails the poll.
    private func refreshAccessoriesIfNeeded(devices: [Device]) async {
        if let lastAccessoryRefresh,
           now().timeIntervalSince(lastAccessoryRefresh) < Double(configuration.accessoryRefresh.components.seconds) {
            return
        }
        guard !devices.isEmpty else { return }
        guard let parts = try? await client.accessories(forDeviceIDs: devices.map(\.id)) else { return }
        lastAccessoryRefresh = now()
        // The batch endpoint is the only one that returns `parentId`, which is
        // the whole reason it is used in preference to per-device calls.
        snapshot.accessories = Dictionary(
            grouping: parts.filter { $0.parentId != nil },
            by: { $0.parentId! }
        )
    }

    /// Same contract as the lookups: alarms are supplementary, so a failure here
    /// leaves the previous list in place and never fails the poll.
    private func refreshAlarmsIfNeeded() async {
        if let lastAlarmRefresh,
           now().timeIntervalSince(lastAlarmRefresh) < Double(configuration.alarmRefresh.components.seconds) {
            return
        }
        guard let result = try? await client.allAlarms(deviceType: configuration.deviceType) else { return }
        lastAlarmRefresh = now()
        snapshot.alarms = result.alarms.filter(\.isActive)
        snapshot.alarmTotal = result.total
    }

    /// Closes settling windows, and raises a real change for any device that did
    /// not come back.
    ///
    /// Without this, a phone that was rebooted and never returned would sit
    /// offline in silence forever: the detector confirmed the drop while it was
    /// still suppressed, so it has nothing further to report.
    private func expireSuppressions(devices: [Device], at moment: Date) {
        let expired = suppressions.filter { $0.value.until <= moment }
        guard !expired.isEmpty else { return }

        let byID = Dictionary(devices.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (id, suppression) in expired {
            suppressions.removeValue(forKey: id)
            guard let device = byID[id], device.deviceStatus != suppression.statusBefore else { continue }
            changeBroadcaster.yield(
                StatusChange(
                    device: device,
                    from: suppression.statusBefore,
                    to: device.deviceStatus,
                    at: moment
                )
            )
        }
    }

    /// Model and site names change rarely, and a failure here must never fail
    /// the poll -- the device list is the point, the names are decoration.
    private func refreshLookupsIfNeeded() async {
        if let lastLookupRefresh,
           now().timeIntervalSince(lastLookupRefresh) < Double(configuration.lookupRefresh.components.seconds) {
            return
        }
        lastLookupRefresh = now()

        var models: [String: String] = [:]
        var types: [String: DeviceType] = [:]
        for type in DeviceType.allCases {
            guard let fetched = try? await client.models(deviceType: type) else { continue }
            for model in fetched {
                // First writer wins, and `allCases` starts at `.phone`. A model
                // id that somehow appears under both types resolves to phone,
                // which is the safer guess for an app that monitors phones.
                if types[model.id] == nil { types[model.id] = type }
                if model.name != nil { models[model.id] = model.name }
            }
        }
        if !models.isEmpty { snapshot.modelNames = models }
        if !types.isEmpty { snapshot.modelTypes = types }

        if let sites = try? await client.listSites() {
            var names: [String: String] = [:]
            for site in sites.items where site.name != nil {
                names[site.id] = site.name
            }
            if !names.isEmpty { snapshot.siteNames = names }
        }
    }

    private func publish() {
        snapshotBroadcaster.yield(snapshot)
    }
}
