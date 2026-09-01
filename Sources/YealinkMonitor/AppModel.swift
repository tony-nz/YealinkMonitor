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
            // A demo run must not write over the preferences of whoever is
            // running it -- opening Settings alone would be enough to do that.
            if !isDemo { settings.save() }
            applySettingsChange(from: oldValue)
        }
    }

    /// Launched with `-demoFleet YES`: a synthetic fleet, no monitor, no
    /// requests and no credentials. See `DemoFleet`.
    let isDemo = DemoFleet.isEnabled

    /// Whether the app has something to show. True in demo mode, where there
    /// are no credentials and nothing to configure.
    var isConfigured: Bool { isDemo || settings.isConfigured }

    let history: HistoryStore
    let email = EmailAlerter()
    let scheduler = RebootScheduler()
    private let notifier = Notifier()

    private var monitor: Monitor?
    private var hasStarted = false
    private var snapshotTask: Task<Void, Never>?
    private var changeTask: Task<Void, Never>?
    private var lifecycleObservers: [any NSObjectProtocol] = []
    private var pathMonitor: NWPathMonitor?

    init(settings: AppSettings? = nil) {
        let isDemo = DemoFleet.isEnabled
        self.settings = settings ?? (isDemo ? DemoFleet.settings() : .load())
        // A demo run keeps its invented history in a scratch file, so it neither
        // reads the real fleet's history nor writes demo entries into it.
        self.history = HistoryStore(url: isDemo ? DemoFleet.historyURL() : nil)
    }

    // MARK: - Lifecycle

    /// Idempotent, and it has to be.
    ///
    /// This is driven from a `.task` on the menu bar popover's content, and with
    /// `.menuBarExtraStyle(.window)` that content is rebuilt every single time
    /// the menu is opened. Without this guard, each click tore down the running
    /// monitor and started a new one with an empty snapshot -- the device list
    /// vanished, the app re-authenticated, and the transition detector re-primed
    /// its baseline so a phone that was already offline would never alert.
    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        // A demo run stops here: no keychain, no notification prompt, no email
        // and no scheduler, so it cannot act on anything real.
        if isDemo {
            snapshot = DemoFleet.snapshot()
            for change in DemoFleet.history() { history.append(change) }
            return
        }
        adoptEmbeddedCredentialsIfNeeded()
        email.update(settings: settings)
        observeSystemEvents()
        configureScheduler()
        // Polling starts first, and nothing above it may block.
        //
        // Asking for notification permission used to happen here, awaited. On a
        // Mac that has not answered the prompt yet -- a fresh install, or a
        // first launch after login -- that await does not return until someone
        // clicks the dialog, and until it returns the monitor does not exist.
        // The app would sit in the menu bar showing no problems while nothing
        // was being checked at all.
        rebuildMonitor()
        Task { await notifier.requestAuthorizationIfNeeded() }
    }

    /// Moves credentials baked into the bundle into the keychain and
    /// preferences, so an embedded build provisions itself on first launch.
    ///
    /// Effectively runs once per machine: afterwards the keychain holds the
    /// secret and this returns early, which means anything the user later
    /// changes in Settings wins over what the bundle shipped with.
    private func adoptEmbeddedCredentialsIfNeeded() {
        // The bundle check comes first, and deliberately so: it reads Info.plist
        // and cannot block, whereas `hasStoredSecret` queries the keychain.
        //
        // A keychain query on the main actor can put up a permission dialog --
        // macOS asks again whenever the app's signature changes, which for an
        // ad-hoc signed build is every single build. While that dialog is up the
        // query does not return, and with this running before `rebuildMonitor`
        // the app would sit in the menu bar having never started polling. An
        // ordinary build has no embedded credentials and now never reaches the
        // keychain here at all.
        guard let embedded = EmbeddedCredentials.current else { return }
        guard !settings.isConfigured || !hasStoredSecret else { return }

        if !hasStoredSecret {
            try? Keychain.writeSecret(embedded.clientSecret)
        }
        var updated = settings
        if updated.clientID.isEmpty { updated.clientID = embedded.clientID }
        if let region = embedded.region { updated.region = region }
        // Assigned once, so didSet fires a single time rather than per field.
        settings = updated
    }

    /// Rebuilt rather than reconfigured whenever the credentials or region
    /// change: a cached token from the old region is worthless.
    private func rebuildMonitor() {
        guard !isDemo else { return }
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
                self.email.receive(change, settings: self.settings)
            }
        }

        Task { await monitor.start() }
    }

    private func applySettingsChange(from old: AppSettings) {
        email.update(settings: settings)
        // Mail queued for a server the user has just changed would fail forever.
        if old.smtpHost != settings.smtpHost
            || old.smtpUsername != settings.smtpUsername
            || old.emailFrom != settings.emailFrom
            || (old.emailEnabled && !settings.emailEnabled)
        {
            email.reset()
        }
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
                guard let self else { return }
                await self.monitor?.start()
                // Anything cached across a sleep is certainly stale.
                await self.monitor?.refreshNow()
                // Waking is exactly when a missed occurrence is discovered.
                await self.scheduler.checkNow()
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

    /// Stores the SMTP password. Kept beside the YMCS secret rather than in
    /// preferences for the same reason: it is a credential.
    func saveSMTPPassword(_ password: String) {
        try? Keychain.writeSecret(password, account: Keychain.smtpAccount)
    }

    var hasStoredSMTPPassword: Bool {
        (try? Keychain.readSecret(account: Keychain.smtpAccount))?.isEmpty == false
    }

    /// Tries each region in turn and adopts the one that authenticates.
    ///
    /// A wrong region and a wrong secret produce the same 401, so guessing is
    /// the only way to tell them apart without asking Yealink.
    func checkConnection(probingRegions: Bool) async {
        guard !isDemo else {
            connectionCheck = .failed("This is a demo fleet. It has no credentials and makes no requests.")
            return
        }
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

    // MARK: - Archiving

    /// Phones that are in service. Everything the app counts, alerts on or acts
    /// on in bulk starts here.
    var activeDevices: [Device] {
        snapshot.devices.filter { !settings.archivedDeviceIDs.contains($0.id) }
    }

    var archivedDevices: [Device] {
        snapshot.devices.filter { settings.archivedDeviceIDs.contains($0.id) }
    }

    func isArchived(_ device: Device) -> Bool {
        settings.archivedDeviceIDs.contains(device.id)
    }

    func setArchived(_ archived: Bool, for devices: [Device]) {
        var updated = settings
        for device in devices {
            if archived {
                updated.archivedDeviceIDs.insert(device.id)
            } else {
                updated.archivedDeviceIDs.remove(device.id)
            }
        }
        settings = updated
    }

    /// Devices needing attention, with muted and archived ones removed.
    ///
    /// An archived phone is not a problem by definition -- a spare in a cupboard
    /// is *meant* to be offline, and a monitor that shows a permanent red
    /// triangle for it teaches you to ignore red triangles.
    var problems: [Device] {
        activeDevices.filter { $0.deviceStatus != .online && !settings.mutedDeviceIDs.contains($0.id) }
            .sorted { lhs, rhs in
                if lhs.deviceStatus != rhs.deviceStatus { return lhs.deviceStatus == .offline }
                return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }
    }

    var mutedProblems: [Device] {
        activeDevices.filter { $0.deviceStatus != .online && settings.mutedDeviceIDs.contains($0.id) }
    }

    /// Phones with at least one active YMCS alarm, worst first.
    ///
    /// Muted devices are excluded for the same reason they are excluded from
    /// `problems`: a mute means "stop telling me about this phone", and an alarm
    /// badge is telling.
    var alarmedDevices: [AlarmedDevice] {
        let byMAC = Dictionary(grouping: snapshot.alarms.filter { $0.normalizedMAC != nil }) {
            $0.normalizedMAC!
        }
        guard !byMAC.isEmpty else { return [] }

        return activeDevices
            .filter { !settings.mutedDeviceIDs.contains($0.id) }
            .compactMap { device in
                guard let alarms = byMAC[Device.normalizeMAC(device.mac)], !alarms.isEmpty else { return nil }
                return AlarmedDevice(
                    device: device,
                    alarms: alarms.sorted { $0.severityRank > $1.severityRank }
                )
            }
            .sorted { lhs, rhs in
                if lhs.worstRank != rhs.worstRank { return lhs.worstRank > rhs.worstRank }
                return lhs.device.displayName.localizedStandardCompare(rhs.device.displayName) == .orderedAscending
            }
    }

    struct AlarmedDevice: Identifiable {
        let device: Device
        let alarms: [Alarm]
        var id: String { device.id }
        var worstRank: Int { alarms.first?.severityRank ?? 0 }
    }

    /// This device's active alarms, worst first, then most recent. Callers that
    /// show only one want the worst one, not the newest.
    func alarms(for device: Device) -> [Alarm] {
        snapshot.alarms(for: device).sorted { lhs, rhs in
            if lhs.severityRank != rhs.severityRank { return lhs.severityRank > rhs.severityRank }
            return (lhs.lastAlarmTime ?? lhs.firstAlarmTime ?? 0) > (rhs.lastAlarmTime ?? rhs.firstAlarmTime ?? 0)
        }
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
        if isDemo {
            guard let detail = snapshot.detail(for: device) else {
                throw YMCSError.notFound(nil)
            }
            return detail
        }
        return try await makeClient().device(id: device.id)
    }

    /// This phone's calls over the last week. Fetched with the detail pane
    /// rather than polled: nothing alerts on it.
    func recentCalls(for device: Device, days: Int = 7) async throws -> [CallRecord] {
        if isDemo {
            let mac = Device.normalizeMAC(device.mac)
            return DemoFleet.calls().filter { $0.normalizedMAC == mac }
        }
        let now = Date()
        return try await makeClient().listCalls(
            limit: 50,
            mac: device.mac,
            since: now.addingTimeInterval(-Double(days) * 86_400),
            until: now
        ).items
    }

    /// Cached per successful poll: the modal-version calculation walks the whole
    /// device list and the table asks once per visible row.
    ///
    /// `@ObservationIgnored` matters -- this is written from inside a view's
    /// body, and an observed write there would invalidate the view that is
    /// currently rendering.
    @ObservationIgnored
    private var firmwareReference: (asOf: Date?, versions: [String: String])?

    func isBehindFleetFirmware(_ device: Device) -> Bool {
        if firmwareReference?.asOf != snapshot.lastSuccess {
            firmwareReference = (snapshot.lastSuccess, snapshot.fleetFirmware)
        }
        return snapshot.isBehindFleetFirmware(device, reference: firmwareReference?.versions)
    }

    func lanIP(for device: Device) -> String? {
        snapshot.lanIP(for: device)
    }

    /// Everything known about these phones, as a CSV.
    ///
    /// Columns the device list alone cannot fill -- IP, serial, SIP lines --
    /// come from the detail sweep, so they read "—" until it has run. That is
    /// stated in the export rather than left as a silently empty column.
    func exportCSV(_ devices: [Device]) -> Data {
        let header = [
            "Name", "MAC", "Serial", "Model", "Site", "Status", "Archived", "LAN IP",
            "Firmware", "Behind fleet firmware", "SIP lines", "Unregistered lines",
            "Accessories", "Accessory faults", "Active alarms", "Last reported",
        ]
        let rows = devices.map { device -> [String] in
            let detail = snapshot.detail(for: device)
            let accounts = detail?.accounts ?? []
            let parts = snapshot.accessories(for: device)
            return [
                device.displayName,
                Device.formatMAC(device.mac),
                detail?.sn ?? device.sn ?? "—",
                snapshot.modelName(for: device) ?? "—",
                snapshot.siteName(for: device) ?? "—",
                device.deviceStatus.rawValue,
                isArchived(device) ? "yes" : "no",
                detail?.lanIp ?? "—",
                device.programVersion ?? "—",
                isBehindFleetFirmware(device) ? "yes" : "no",
                accounts.isEmpty ? "—" : String(accounts.count),
                accounts.isEmpty ? "—" : String(accounts.count { $0.status?.isHealthy == false }),
                parts.isEmpty ? "—" : String(parts.count),
                parts.isEmpty ? "—" : String(parts.count(where: \.isProblem)),
                String(alarms(for: device).count),
                detail?.lastReportDate.map { Format.iso($0) } ?? "—",
            ]
        }
        return CSV.document(header: header, rows: rows)
    }

    func accessories(for device: Device) -> [Accessory] {
        snapshot.accessories(for: device)
    }

    /// A client for one-off calls the polling loop does not make. Cheap to
    /// build: the token cache lives in the keychain-backed provider's store, so
    /// this costs an authentication the first time and nothing afterwards.
    ///
    /// Throws in a demo run rather than handing back a client. A demo has no
    /// credentials of its own, and the keychain on the Mac running it may well
    /// hold real ones -- so without this, a diagnostic or an accessory restart
    /// launched from the demo would authenticate as the real enterprise.
    func makeClient() throws -> YMCSClient {
        guard !isDemo else { throw YMCSError.notConfigured }
        return YMCSClient(
            credentialsProvider: KeychainCredentialsProvider(
                clientID: settings.clientID,
                region: settings.region
            )
        )
    }

    // MARK: - Reboot

    /// What one reboot request did, in a form the UI can show without having to
    /// know the API's batch semantics.
    struct RebootReport: Identifiable, Equatable {
        let id = UUID()
        let at: Date
        let requested: [String]
        let result: RebootResult?
        let errorMessage: String?

        var isFailure: Bool { errorMessage != nil }

        var title: String {
            if errorMessage != nil { return "Restart failed" }
            guard let result else { return "Restart sent" }
            if result.failureCount > 0 { return "Restart partly failed" }
            return requested.count == 1 ? "Restarting \(requested[0])" : "Restarting \(requested.count) phones"
        }

        var message: String {
            if let errorMessage { return errorMessage }
            guard let result else { return "" }
            var lines: [String] = []
            if result.failureCount > 0 {
                lines.append("\(result.successCount) of \(result.total) accepted; \(result.failureCount) failed.")
                // The ids are meaningless to a human, so only the reasons are
                // shown, deduplicated -- forty identical lines help nobody.
                let reasons = Set((result.errors ?? []).compactMap(\.msg)).sorted()
                lines.append(contentsOf: reasons)
            } else {
                lines.append("YMCS accepted the request for \(result.successCount) phone\(result.successCount == 1 ? "" : "s").")
            }
            lines.append("Phones take a minute or two to come back. Any that are offline now will not receive it.")
            return lines.joined(separator: "\n")
        }
    }

    private(set) var rebootingDeviceIDs: Set<String> = []

    /// True while a reboot request for this device is in flight. Distinct from
    /// the settling window afterwards, which is the Monitor's business.
    func isRebooting(_ device: Device) -> Bool {
        rebootingDeviceIDs.contains(device.id)
    }

    /// Restarts phones. The caller is responsible for having confirmed with the
    /// user first: nothing below asks.
    func reboot(_ devices: [Device]) async -> RebootReport {
        await reboot(ids: devices.map(\.id), names: devices.map(\.displayName))
    }

    /// Restarts by id, for callers whose devices may no longer be in the
    /// snapshot -- a saved schedule, for instance.
    func reboot(ids: [String], names: [String]) async -> RebootReport {
        guard let monitor else {
            return RebootReport(
                at: Date(), requested: names, result: nil,
                errorMessage: "Not connected to YMCS."
            )
        }

        rebootingDeviceIDs.formUnion(ids)
        defer { rebootingDeviceIDs.subtract(ids) }

        do {
            let result = try await monitor.reboot(
                deviceIDs: ids,
                settlingWindow: .seconds(max(60, settings.rebootSettlingSeconds))
            )
            // The phones are about to drop; start watching for it now rather
            // than at the next heartbeat.
            refresh()
            return RebootReport(at: Date(), requested: names, result: result, errorMessage: nil)
        } catch {
            let message = (error as? YMCSError)?.errorDescription ?? error.localizedDescription
            return RebootReport(at: Date(), requested: names, result: nil, errorMessage: message)
        }
    }


    /// Restarts accessories on one phone. Unlike a device restart this does not
    /// drop the phone, so there is no settling window to arrange.
    func rebootAccessories(on device: Device, parts: [Accessory]) async -> RebootReport {
        let names = parts.isEmpty ? ["all accessories"] : parts.map(\.displayName)
        do {
            let result = try await makeClient().rebootAccessories(
                deviceID: device.id,
                partIDs: parts.map(\.id)
            )
            return RebootReport(at: Date(), requested: names, result: result, errorMessage: nil)
        } catch {
            let message = (error as? YMCSError)?.errorDescription ?? error.localizedDescription
            return RebootReport(at: Date(), requested: names, result: nil, errorMessage: message)
        }
    }

    // MARK: - Scheduled restarts

    private func configureScheduler() {
        scheduler.schedules = { [weak self] in self?.settings.rebootSchedules ?? [] }
        scheduler.graceSeconds = { [weak self] in
            Double(max(5, self?.settings.scheduleGraceMinutes ?? 60)) * 60
        }
        scheduler.run = { [weak self] schedule in
            guard let self else { return .failed(message: "The app is shutting down.") }
            return await self.runSchedule(schedule)
        }
        scheduler.record = { [weak self] id, occurrence, outcome in
            self?.recordScheduleOutcome(id: id, occurrence: occurrence, outcome: outcome)
        }
        scheduler.start()
    }

    private func runSchedule(_ schedule: RebootSchedule) async -> RebootSchedule.Outcome {
        // Names for the report. A device that has since been removed from YMCS
        // keeps its id so the report can say which one is missing.
        let known = Dictionary(
            snapshot.devices.map { ($0.id, $0.displayName) },
            uniquingKeysWith: { first, _ in first }
        )
        let names = schedule.deviceIDs.map { known[$0] ?? "Unknown device (\($0))" }

        let report = await reboot(ids: schedule.deviceIDs, names: names)
        let outcome: RebootSchedule.Outcome
        if let error = report.errorMessage {
            outcome = .failed(message: error)
        } else if let result = report.result {
            outcome = .fired(
                total: result.total,
                succeeded: result.successCount,
                failed: result.failureCount
            )
        } else {
            outcome = .failed(message: "No response from YMCS.")
        }

        // Nobody is watching at 3am, so the report has to come to them.
        announce(schedule: schedule, names: names, outcome: outcome, report: report)
        return outcome
    }

    private func announce(
        schedule: RebootSchedule,
        names: [String],
        outcome: RebootSchedule.Outcome,
        report: RebootReport
    ) {
        let title = outcome.isFailure
            ? "Scheduled restart “\(schedule.name)” had failures"
            : "Scheduled restart “\(schedule.name)” ran"

        var lines = [scheduleSummary(outcome)]
        lines.append("")
        lines.append("Phones:")
        lines.append(contentsOf: names.map { "  \($0)" })
        if let errors = report.result?.errors, !errors.isEmpty {
            lines.append("")
            lines.append("Errors:")
            lines.append(contentsOf: Set(errors.compactMap(\.msg)).sorted().map { "  \($0)" })
        }

        notifier.postReport(title: title, body: scheduleSummary(outcome))
        email.enqueue(subject: title, body: lines.joined(separator: "\n"), settings: settings)
    }

    private func scheduleSummary(_ outcome: RebootSchedule.Outcome) -> String {
        switch outcome {
        case .fired(let total, let succeeded, let failed):
            failed > 0
                ? "\(succeeded) of \(total) phones accepted the restart; \(failed) failed."
                : "All \(total) phones accepted the restart."
        case .firedLate(let minutes):
            "Ran \(minutes) minutes late — the Mac was probably asleep at the scheduled time."
        case .skipped(let reason):
            reason
        case .failed(let message):
            message
        }
    }

    private func recordScheduleOutcome(id: UUID, occurrence: Date, outcome: RebootSchedule.Outcome) {
        guard let index = settings.rebootSchedules.firstIndex(where: { $0.id == id }) else { return }
        var updated = settings
        // Stamped with the occurrence, not with now: stamping "now" on a run
        // that started at 03:00 and finished at 03:02 would leave the 03:00
        // occurrence looking unhandled if the clock were read differently.
        updated.rebootSchedules[index].lastFired = occurrence
        updated.rebootSchedules[index].lastOutcome = outcome
        settings = updated
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
