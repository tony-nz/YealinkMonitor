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
    public var siteNames: [String: String] = [:]
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

    public func siteName(for device: Device) -> String? {
        device.siteId.flatMap { siteNames[$0] }
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
/// The API has no webhooks, so this is the only way to learn about a phone
/// dropping. The loop is built around the enterprise-wide 50 req/s budget being
/// shared with whatever else uses the same credentials, so it stays cheap:
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
    private var runTask: Task<Void, Never>?

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
        publish()
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

        for change in detector.ingest(devices, at: now()) {
            changeBroadcaster.yield(change)
        }

        await refreshLookupsIfNeeded()
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
        for type in DeviceType.allCases {
            guard let fetched = try? await client.models(deviceType: type) else { continue }
            for model in fetched where model.name != nil {
                models[model.id] = model.name
            }
        }
        if !models.isEmpty { snapshot.modelNames = models }

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
