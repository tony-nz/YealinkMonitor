import AppKit
import Foundation
import Network
import Observation
import ServiceManagement
import YMCSKit

@MainActor
@Observable
final class AppModel {
    enum ConnectionCheck: Equatable {
        case idle
        case checking
        case succeeded(Region)
        case failed(String)
    }

    private(set) var snapshot = MonitorSnapshot()
    private(set) var connectionCheck: ConnectionCheck = .idle
    private(set) var isOnNetwork = true

    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            applySettingsChange(from: oldValue)
        }
    }

    let history = HistoryStore()
    private let notifier = Notifier()

    private var monitor: Monitor?
    private var snapshotTask: Task<Void, Never>?
    private var changeTask: Task<Void, Never>?
    private var lifecycleObservers: [any NSObjectProtocol] = []
    private var pathMonitor: NWPathMonitor?

    init(settings: AppSettings = .load()) {
        self.settings = settings
    }

    // MARK: - Lifecycle

    func start() async {
        await notifier.requestAuthorizationIfNeeded()
        observeSystemEvents()
        rebuildMonitor()
    }

    /// Rebuilt rather than reconfigured whenever the credentials or region
    /// change: a cached token from the old region is worthless.
    private func rebuildMonitor() {
        snapshotTask?.cancel()
        changeTask?.cancel()
        let previous = monitor
        Task { await previous?.stop() }

        guard settings.isConfigured else {
            monitor = nil
            snapshot = MonitorSnapshot()
            return
        }

        let client = YMCSClient(
            credentialsProvider: KeychainCredentialsProvider(
                clientID: settings.clientID,
                region: settings.region
            )
        )
        let monitor = Monitor(client: client, configuration: settings.monitorConfiguration)
        self.monitor = monitor

        let snapshots = monitor.snapshots
        snapshotTask = Task { [weak self] in
            for await value in snapshots {
                guard let self else { return }
                self.snapshot = value
            }
        }

        let changes = monitor.changes
        changeTask = Task { [weak self] in
            for await change in changes {
                guard let self else { return }
                self.history.append(change)
                self.notifier.post(change, settings: self.settings, snapshot: self.snapshot)
            }
        }

        Task { await monitor.start() }
    }

    private func applySettingsChange(from old: AppSettings) {
        if old.clientID != settings.clientID || old.region != settings.region {
            connectionCheck = .idle
            rebuildMonitor()
            return
        }
        if old.monitorConfiguration.heartbeat != settings.monitorConfiguration.heartbeat
            || old.confirmations != settings.confirmations
            || old.deviceTypeFilter != settings.deviceTypeFilter
            || old.fullRefreshSeconds != settings.fullRefreshSeconds
        {
            let configuration = settings.monitorConfiguration
            Task { [monitor] in await monitor?.update(configuration: configuration) }
        }
    }

    func refresh() {
        Task { [monitor] in await monitor?.refreshNow() }
    }

    // MARK: - System events

    /// A menu bar app runs for weeks across sleeps, network changes and VPN
    /// flaps. Without these hooks it wakes up showing hours-old data and quietly
    /// reports every phone as fine.
    private func observeSystemEvents() {
        guard lifecycleObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter

        lifecycleObservers.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.monitor?.stop() }
        })

        lifecycleObservers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let monitor = self?.monitor else { return }
                await monitor.start()
                // Anything cached across a sleep is certainly stale.
                await monitor.refreshNow()
            }
        })

        let pathMonitor = NWPathMonitor()
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let wasOffNetwork = !self.isOnNetwork
                self.isOnNetwork = path.status == .satisfied
                // Poll the moment connectivity returns rather than waiting out
                // the remainder of the interval.
                if wasOffNetwork && self.isOnNetwork { self.refresh() }
            }
        }
        pathMonitor.start(queue: .main)
        self.pathMonitor = pathMonitor
    }

    // MARK: - Credentials

    /// Stores the secret and re-checks the connection.
    func saveSecret(_ secret: String) {
        do {
            try Keychain.writeSecret(secret)
            rebuildMonitor()
        } catch {
            connectionCheck = .failed(error.localizedDescription)
        }
    }

    var hasStoredSecret: Bool {
        (try? Keychain.readSecret())?.isEmpty == false
    }

    /// Tries each region in turn and adopts the one that authenticates.
    ///
    /// A wrong region and a wrong secret produce the same 401, so guessing is
    /// the only way to tell them apart without asking Yealink.
    func checkConnection(probingRegions: Bool) async {
        guard settings.isConfigured, hasStoredSecret else {
            connectionCheck = .failed("Enter a Client ID and Secret first.")
            return
        }
        connectionCheck = .checking

        let candidates = probingRegions
            ? [settings.region] + Region.probeOrder.filter { $0 != settings.region }
            : [settings.region]

        var lastMessage = "Could not connect."
        for region in candidates {
            let client = YMCSClient(
                credentialsProvider: KeychainCredentialsProvider(
                    clientID: settings.clientID,
                    region: region
                )
            )
            do {
                try await client.verifyConnection()
                connectionCheck = .succeeded(region)
                if settings.region != region { settings.region = region }
                return
            } catch let error as YMCSError {
                lastMessage = error.errorDescription ?? "\(error)"
                // A network failure says nothing about the region, so trying
                // the others would just produce three identical errors.
                if case .transport = error { break }
            } catch {
                lastMessage = error.localizedDescription
                break
            }
        }
        connectionCheck = .failed(lastMessage)
    }

    // MARK: - Presentation

    var isStale: Bool {
        snapshot.isStale(tolerance: settings.monitorConfiguration.staleTolerance)
    }

    /// Devices needing attention, with muted ones removed.
    var problems: [Device] {
        snapshot.problems.filter { !settings.mutedDeviceIDs.contains($0.id) }
    }

    var mutedProblems: [Device] {
        snapshot.problems.filter { settings.mutedDeviceIDs.contains($0.id) }
    }

    func isMuted(_ device: Device) -> Bool {
        settings.mutedDeviceIDs.contains(device.id)
    }

    func toggleMute(_ device: Device) {
        if settings.mutedDeviceIDs.contains(device.id) {
            settings.mutedDeviceIDs.remove(device.id)
        } else {
            settings.mutedDeviceIDs.insert(device.id)
        }
    }

    func detail(for device: Device) async throws -> DeviceDetail {
        let client = YMCSClient(
            credentialsProvider: KeychainCredentialsProvider(
                clientID: settings.clientID,
                region: settings.region
            )
        )
        return try await client.device(id: device.id)
    }

    // MARK: - Launch at login

    var launchesAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setLaunchesAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Unavailable for an unsigned or unbundled build; not fatal.
        }
    }
}
