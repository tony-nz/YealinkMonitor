import Foundation
import YMCSKit

/// A synthetic fleet, used for screenshots and for looking at the app without a
/// YMCS tenant.
///
/// Enabled by launching with `-demoFleet YES`:
///
///     /Applications/YealinkMonitor.app/Contents/MacOS/YealinkMonitor -demoFleet YES
///
/// Two things it deliberately does not do. It never creates a `Monitor`, so no
/// request is made and no credential is read -- a demo run works on a Mac that
/// has never been provisioned. And it substitutes its own `AppSettings` rather
/// than loading the real ones, with saving suppressed, so a demo session cannot
/// show or overwrite the settings of whoever is running it.
///
/// The fleet is invented: an organisation, four sites and twenty-six phones that
/// do not exist. It is arranged to contain one of everything worth documenting
/// -- an outage, a phone that never provisioned, a phone that is online with an
/// unregistered line, a dead expansion module, firmware drift, and an archived
/// spare -- because a screenshot of a fleet where nothing is wrong shows none of
/// what the app is for.
enum DemoFleet {
    /// Read from the argument domain, so `-demoFleet YES` on the command line is
    /// enough and nothing is written to the user's preferences.
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "demoFleet") }

    // MARK: - Fleet definition

    private struct Spec {
        let name: String
        let model: String
        let site: String
        /// Nil for a phone that has never reported in.
        let ip: String?
        let status: DeviceStatus
        var firmware: String?
        var lines: Int = 1
        /// How many of `lines` are not registered.
        var unregistered: Int = 0
        var accessory: (model: String, way: String, status: Accessory.ConnectionStatus)?
        var alarm: (event: String, level: Alarm.Level, agedMinutes: Int)?
        var archived = false
        /// Minutes since the device last reported to YMCS.
        var lastReportAgeMinutes: Int = 3
    }

    private static let modelNames: [String: String] = [
        "m-t31p": "SIP-T31P",
        "m-t33g": "SIP-T33G",
        "m-t43u": "SIP-T43U",
        "m-t46u": "SIP-T46U",
        "m-t54w": "SIP-T54W",
        "m-mp56": "MP56",
    ]

    private static let siteNames: [String: String] = [
        "s-head": "Head Office",
        "s-river": "Riverside Branch",
        "s-ware": "Warehouse",
        "s-support": "Support Desk",
    ]

    /// The version most of each model runs. One phone is held below its own so
    /// the firmware-drift marker has something to mark.
    private static let currentFirmware: [String: String] = [
        "m-t31p": "124.86.0.110",
        "m-t33g": "124.86.0.110",
        "m-t43u": "108.86.0.90",
        "m-t46u": "108.86.0.90",
        "m-t54w": "96.86.0.85",
        "m-mp56": "122.15.0.44",
    ]

    private static let specs: [Spec] = [
        // Head Office
        Spec(name: "Reception", model: "m-t46u", site: "s-head", ip: "10.20.30.11",
             status: .online, lines: 2,
             accessory: ("WH62 Mono", "USB", .online)),
        Spec(name: "Boardroom", model: "m-t54w", site: "s-head", ip: "10.20.30.12",
             status: .online,
             accessory: ("CP900", "USB", .online)),
        Spec(name: "Finance 1", model: "m-t43u", site: "s-head", ip: "10.20.30.13", status: .online),
        Spec(name: "Finance 2", model: "m-t43u", site: "s-head", ip: "10.20.30.14", status: .online),
        Spec(name: "Sales 1", model: "m-t43u", site: "s-head", ip: "10.20.30.15", status: .online),
        // Online, and cannot take calls on one of its two lines. The status
        // column alone would call this phone healthy.
        Spec(name: "Sales 2", model: "m-t43u", site: "s-head", ip: "10.20.30.16",
             status: .online, lines: 2, unregistered: 1,
             alarm: ("Register Failed", .major, 47)),
        Spec(name: "Sales 3", model: "m-t43u", site: "s-head", ip: "10.20.30.17", status: .online),
        Spec(name: "HR Office", model: "m-t33g", site: "s-head", ip: "10.20.30.18", status: .online),
        // Online with a dead expansion module.
        Spec(name: "IT Office", model: "m-t46u", site: "s-head", ip: "10.20.30.19",
             status: .online,
             accessory: ("EXP43", "RJ45", .offline)),
        // Deliberately held back a build.
        Spec(name: "Kitchen", model: "m-t31p", site: "s-head", ip: "10.20.30.20",
             status: .online, firmware: "124.86.0.40"),
        Spec(name: "Print Room", model: "m-t31p", site: "s-head", ip: "10.20.30.21",
             status: .offline,
             alarm: ("Offline", .major, 18),
             lastReportAgeMinutes: 19),
        Spec(name: "Meeting Room 2", model: "m-mp56", site: "s-head", ip: "10.20.30.22", status: .online),

        // Riverside Branch
        Spec(name: "Branch Reception", model: "m-t46u", site: "s-river", ip: "10.20.31.11",
             status: .online, lines: 2),
        Spec(name: "Branch Desk 1", model: "m-t33g", site: "s-river", ip: "10.20.31.12", status: .online),
        Spec(name: "Branch Desk 2", model: "m-t33g", site: "s-river", ip: "10.20.31.13", status: .online),
        Spec(name: "Branch Desk 3", model: "m-t33g", site: "s-river", ip: "10.20.31.14",
             status: .offline,
             alarm: ("Offline", .critical, 214),
             lastReportAgeMinutes: 215),
        Spec(name: "Branch Manager", model: "m-t54w", site: "s-river", ip: "10.20.31.15", status: .online),

        // Warehouse
        Spec(name: "Goods In", model: "m-t31p", site: "s-ware", ip: "10.20.32.11", status: .online),
        Spec(name: "Dispatch", model: "m-t31p", site: "s-ware", ip: "10.20.32.12", status: .online),
        Spec(name: "Warehouse Office", model: "m-t43u", site: "s-ware", ip: "10.20.32.13", status: .online),
        Spec(name: "Loading Bay", model: "m-t31p", site: "s-ware", ip: "10.20.32.14",
             status: .offline, lastReportAgeMinutes: 6),
        // Registered in YMCS and never powered on. Collapsing this into
        // "offline" would hide a different kind of problem.
        Spec(name: "Forklift Bay (new)", model: "m-t31p", site: "s-ware", ip: nil,
             status: .pending, firmware: "", lastReportAgeMinutes: 0),

        // Support Desk
        Spec(name: "Support 1", model: "m-t46u", site: "s-support", ip: "10.20.33.11",
             status: .online, lines: 2),
        Spec(name: "Support 2", model: "m-t46u", site: "s-support", ip: "10.20.33.12",
             status: .online, lines: 2),
        Spec(name: "Support 3", model: "m-t46u", site: "s-support", ip: "10.20.33.13",
             status: .online, lines: 2),

        // A spare in a cupboard: meant to be offline, so archived rather than
        // muted. It must not appear in the counts, the popover or Restart All.
        Spec(name: "Old Reception Handset", model: "m-t31p", site: "s-ware", ip: nil,
             status: .offline, archived: true, lastReportAgeMinutes: 40_320),
    ]

    // MARK: - Derived identity

    private static func id(_ index: Int) -> String { String(format: "demo-%03d", index) }

    /// A Yealink OUI with an invented suffix. Realistic to look at, and not a
    /// MAC that exists.
    private static func mac(_ index: Int) -> String {
        String(format: "001565%06x", 0xC0_00_00 + index * 0x1D)
    }

    private static func serial(_ index: Int) -> String {
        String(format: "8410%08d", 62_000_000 + index * 1_367)
    }

    private static func firmware(_ spec: Spec) -> String {
        spec.firmware ?? currentFirmware[spec.model] ?? ""
    }

    private static var archivedIDs: Set<String> {
        Set(specs.indices.filter { specs[$0].archived }.map(id))
    }

    // MARK: - Snapshot

    /// Built fresh on each call, because the timestamps are relative to now: a
    /// snapshot with a fixed `lastSuccess` reads as stale a few minutes later,
    /// and the whole window would be captioned as out of date.
    static func snapshot(now: Date = Date()) -> MonitorSnapshot {
        var snapshot = MonitorSnapshot()
        snapshot.modelNames = modelNames
        snapshot.modelTypes = modelNames.mapValues { _ in DeviceType.phone }
        snapshot.siteNames = siteNames
        snapshot.lastSuccess = now
        snapshot.lastAttempt = now
        snapshot.isPolling = false

        for (index, spec) in specs.enumerated() {
            let deviceID = id(index)
            let deviceMAC = mac(index)

            snapshot.devices.append(
                Device(
                    id: deviceID,
                    mac: deviceMAC,
                    sn: serial(index),
                    name: spec.name,
                    modelId: spec.model,
                    siteId: spec.site,
                    programVersion: firmware(spec),
                    deviceStatus: spec.status
                )
            )

            if let detail = detail(spec, id: deviceID, mac: deviceMAC, index: index, now: now) {
                snapshot.details[deviceID] = detail
            }

            if let accessory = spec.accessory {
                snapshot.accessories[deviceID] = [
                    Accessory(
                        id: "\(deviceID)-part",
                        parentId: deviceID,
                        mac: String(format: "001565%06x", 0xD0_00_00 + index * 0x1D),
                        sn: serial(index + 500),
                        modelName: accessory.model,
                        productType: accessory.model,
                        connectWay: accessory.way,
                        connStatus: accessory.status,
                        programVersion: "1.4.0.12",
                        hardwareVersion: "1.0.0.1",
                        lastReportTime: epochMillis(now.addingTimeInterval(-240))
                    )
                ]
            }

            if let alarm = spec.alarm,
               let value = alarmRecord(alarm, id: deviceID, mac: deviceMAC, spec: spec, now: now) {
                snapshot.alarms.append(value)
            }
        }

        snapshot.alarmTotal = Int64(snapshot.alarms.count)
        return snapshot
    }

    private static func detail(
        _ spec: Spec,
        id deviceID: String,
        mac deviceMAC: String,
        index: Int,
        now: Date
    ) -> DeviceDetail? {
        // A phone that has never reported has no detail record worth showing.
        guard spec.status != .pending else { return nil }

        let accounts: [[String: Any]] = (0..<spec.lines).map { line in
            let healthy = line >= spec.unregistered
            return [
                "accountId": "\(deviceID)-line\(line + 1)",
                "lineId": line + 1,
                "accountType": 0,
                "accountServer": "sip.example.net",
                "registerName": "\(2000 + index * 3 + line)",
                "username": "\(2000 + index * 3 + line)",
                "status": (spec.status == .online && healthy
                    ? AccountStatus.registered
                    : AccountStatus.unregistered).rawValue,
            ]
        }

        return decode(DeviceDetail.self, [
            "id": deviceID,
            "mac": deviceMAC,
            "sn": serial(index),
            "name": spec.name,
            "modelId": spec.model,
            "modelName": modelNames[spec.model] ?? spec.model,
            "siteId": spec.site,
            "siteName": siteNames[spec.site] ?? spec.site,
            "lanIp": spec.ip as Any,
            "deviceStatus": spec.status.rawValue,
            "programVersion": firmware(spec),
            "lastReportTime": epochMillis(now.addingTimeInterval(-Double(spec.lastReportAgeMinutes) * 60)),
            "accounts": accounts,
        ])
    }

    private static func alarmRecord(
        _ alarm: (event: String, level: Alarm.Level, agedMinutes: Int),
        id deviceID: String,
        mac deviceMAC: String,
        spec: Spec,
        now: Date
    ) -> Alarm? {
        let raised = now.addingTimeInterval(-Double(alarm.agedMinutes) * 60)
        return decode(Alarm.self, [
            "id": "\(deviceID)-alarm",
            "event": alarm.event,
            "level": alarm.level.rawValue,
            "mac": deviceMAC,
            "model": modelNames[spec.model] ?? spec.model,
            "ip": spec.ip as Any,
            "siteName": siteNames[spec.site] ?? spec.site,
            "status": Alarm.Status.active.rawValue,
            "firstAlarmTime": epochMillis(raised),
            "lastAlarmTime": epochMillis(now.addingTimeInterval(-120)),
        ])
    }

    // MARK: - Activity

    /// Enough calls to show the spread the Activity window exists to reveal,
    /// including a phone that is online around the clock and rates Bad.
    static func calls(now: Date = Date()) -> [CallRecord] {
        struct CallSpec {
            let deviceIndex: Int
            let quality: CallRecord.Quality
            let minutesAgo: Int
            let seconds: Int
            let inMOS: Double
            let outMOS: Double
        }

        let plan: [CallSpec] = [
            CallSpec(deviceIndex: 0, quality: .good, minutesAgo: 12, seconds: 214, inMOS: 4.4, outMOS: 4.3),
            CallSpec(deviceIndex: 22, quality: .good, minutesAgo: 26, seconds: 88, inMOS: 4.5, outMOS: 4.4),
            CallSpec(deviceIndex: 5, quality: .bad, minutesAgo: 41, seconds: 132, inMOS: 2.1, outMOS: 3.9),
            CallSpec(deviceIndex: 12, quality: .good, minutesAgo: 63, seconds: 41, inMOS: 4.3, outMOS: 4.4),
            CallSpec(deviceIndex: 5, quality: .bad, minutesAgo: 77, seconds: 306, inMOS: 1.9, outMOS: 4.0),
            CallSpec(deviceIndex: 3, quality: .good, minutesAgo: 95, seconds: 154, inMOS: 4.2, outMOS: 4.4),
            CallSpec(deviceIndex: 15, quality: .poor, minutesAgo: 118, seconds: 62, inMOS: 3.2, outMOS: 3.4),
            CallSpec(deviceIndex: 23, quality: .good, minutesAgo: 141, seconds: 271, inMOS: 4.4, outMOS: 4.5),
            CallSpec(deviceIndex: 5, quality: .bad, minutesAgo: 166, seconds: 97, inMOS: 2.0, outMOS: 3.8),
            CallSpec(deviceIndex: 1, quality: .good, minutesAgo: 190, seconds: 1_842, inMOS: 4.5, outMOS: 4.5),
            CallSpec(deviceIndex: 24, quality: .poor, minutesAgo: 214, seconds: 46, inMOS: 3.3, outMOS: 3.1),
            CallSpec(deviceIndex: 0, quality: .good, minutesAgo: 250, seconds: 119, inMOS: 4.4, outMOS: 4.2),
        ]

        return plan.enumerated().compactMap { offset, call in
            let spec = specs[call.deviceIndex]
            let start = now.addingTimeInterval(-Double(call.minutesAgo) * 60)
            return decode(CallRecord.self, [
                "id": "demo-call-\(offset)",
                "deviceName": spec.name,
                "mac": mac(call.deviceIndex),
                "modelName": modelNames[spec.model] ?? spec.model,
                "firmwareVersion": firmware(spec),
                "username": "\(2000 + call.deviceIndex * 3)",
                "displayName": spec.name,
                "siteName": siteNames[spec.site] ?? spec.site,
                "quality": call.quality.rawValue,
                "startTime": epochMillis(start),
                "endTime": epochMillis(start.addingTimeInterval(Double(call.seconds))),
                // Null on every tenant seen so far, and null here for the same
                // reason: a screenshot should not promise a column that never
                // fills in practice.
                "callerURI": NSNull(),
                "calleeURI": NSNull(),
                "duration": call.seconds,
                "inConversationalMosAvg": call.inMOS,
                "outConversationalMosAvg": call.outMOS,
            ])
        }
    }

    static func statistics() -> QualityStatistics {
        QualityStatistics(total: 148, badTotal: 6, badPercentage: 4.1, goodPercentage: 91.2)
    }

    static func logs(now: Date = Date()) -> [OperationLog] {
        struct LogSpec {
            let type: String
            let object: String
            let who: String
            let minutesAgo: Int
            var result = "Success"
        }

        let plan: [LogSpec] = [
            LogSpec(type: "i18n.yiot.backend.operation.device.management.restart",
                    object: "Print Room", who: "YealinkMonitor", minutesAgo: 14),
            LogSpec(type: "i18n.yiot.backend.operation.device.management.restart",
                    object: "Loading Bay", who: "YealinkMonitor", minutesAgo: 15),
            LogSpec(type: "i18n.yiot.backend.operation.device.config.push",
                    object: "Sales 2", who: "admin@example.net", minutesAgo: 52),
            LogSpec(type: "i18n.yiot.backend.operation.device.management.add",
                    object: "Forklift Bay (new)", who: "admin@example.net", minutesAgo: 188),
            LogSpec(type: "i18n.yiot.backend.operation.site.management.edit",
                    object: "Warehouse", who: "admin@example.net", minutesAgo: 240),
            LogSpec(type: "i18n.yiot.backend.operation.device.management.restart",
                    object: "Branch Desk 3", who: "YealinkMonitor", minutesAgo: 301,
                    result: "Failure"),
            LogSpec(type: "i18n.yiot.backend.operation.account.management.edit",
                    object: "2015", who: "admin@example.net", minutesAgo: 366),
            LogSpec(type: "i18n.yiot.backend.operation.device.firmware.push",
                    object: "SIP-T43U", who: "admin@example.net", minutesAgo: 1_460),
            LogSpec(type: "i18n.yiot.backend.operation.device.management.restart",
                    object: "Head Office (12 devices)", who: "YealinkMonitor", minutesAgo: 1_620),
            LogSpec(type: "i18n.yiot.backend.operation.system.integration.edit",
                    object: "API AccessKey", who: "admin@example.net", minutesAgo: 4_320),
        ]

        return plan.map { entry in
            OperationLog(
                module: "Device Management",
                operationType: entry.type,
                operationObject: entry.object,
                operator: entry.who,
                ip: "203.0.113.24",
                createTime: epochMillis(now.addingTimeInterval(-Double(entry.minutesAgo) * 60)),
                result: entry.result
            )
        }
    }

    // MARK: - History

    /// Status changes for the detail pane's history section: the phones that are
    /// currently down, plus one that has dropped repeatedly, which is the
    /// pattern on-disk history exists to expose.
    static func history(now: Date = Date()) -> [StatusChange] {
        func device(_ index: Int) -> Device {
            let spec = specs[index]
            return Device(
                id: id(index),
                mac: mac(index),
                sn: serial(index),
                name: spec.name,
                modelId: spec.model,
                siteId: spec.site,
                programVersion: firmware(spec),
                deviceStatus: spec.status
            )
        }

        // (device index, to, minutes ago, cause)
        let plan: [(Int, DeviceStatus, Int, StatusChange.Cause)] = [
            (10, .offline, 18, .observed),
            (20, .offline, 6, .observed),
            (15, .offline, 214, .observed),
            (15, .online, 1_190, .observed),
            (15, .offline, 1_247, .observed),
            (15, .online, 2_630, .observed),
            (15, .offline, 2_702, .observed),
            (10, .online, 1_618, .reboot),
            (10, .offline, 1_620, .reboot),
        ]

        return plan.map { index, to, minutesAgo, cause in
            StatusChange(
                device: device(index),
                from: to == .offline ? .online : .offline,
                to: to,
                at: now.addingTimeInterval(-Double(minutesAgo) * 60),
                cause: cause
            )
        }
    }

    /// Where a demo run keeps its history. Deliberately a scratch file, and
    /// deliberately emptied on each launch: the demo history is seeded at start,
    /// so a persistent file would accumulate a duplicate set every run.
    static func historyURL() -> URL {
        let url = URL.temporaryDirectory.appending(path: "YealinkMonitorDemoHistory.json")
        try? FileManager.default.removeItem(at: url)
        return url
    }

    // MARK: - Settings

    /// Stand-in settings for a demo run.
    ///
    /// Never loaded from and never written to the user's preferences: a demo is
    /// often run to take screenshots of the Settings window, and those must not
    /// be of somebody's real SMTP relay and recipient list.
    static func settings() -> AppSettings {
        var settings = AppSettings()
        settings.clientID = "0123456789abcdef0123456789abcdef"
        settings.region = .au
        settings.heartbeatSeconds = 60
        settings.fullRefreshSeconds = 600
        settings.confirmations = 2
        settings.notificationsEnabled = true
        settings.notifyOnRecovery = true
        settings.quietHoursStart = 22
        settings.quietHoursEnd = 7

        settings.emailEnabled = true
        settings.emailRecipients = ["helpdesk@example.net", "oncall@example.net"]
        settings.emailFrom = "yealinkmonitor@example.net"
        settings.smtpHost = "smtp.example.net"
        settings.smtpPort = 587
        settings.smtpEncryption = .startTLS
        settings.smtpUsername = "yealinkmonitor@example.net"
        settings.emailWindowSeconds = 60
        settings.emailMaximumPerHour = 12
        settings.emailOnRecovery = true
        settings.emailRespectsQuietHours = false

        settings.archivedDeviceIDs = archivedIDs
        settings.mutedDeviceIDs = [id(9)]

        settings.rebootSchedules = [
            RebootSchedule(
                name: "Warehouse weekly",
                deviceIDs: [17, 18, 19, 20].map(id),
                hour: 3,
                minute: 30,
                weekdays: [1],
                isEnabled: true,
                lastFired: Date().addingTimeInterval(-3 * 86_400),
                lastOutcome: .fired(total: 4, succeeded: 4, failed: 0)
            ),
            RebootSchedule(
                name: "Branch overnight",
                deviceIDs: [12, 13, 14, 15, 16].map(id),
                hour: 2,
                minute: 0,
                weekdays: [2, 3, 4, 5, 6],
                isEnabled: true,
                lastFired: Date().addingTimeInterval(-86_400),
                lastOutcome: .fired(total: 5, succeeded: 4, failed: 1)
            ),
        ]
        return settings
    }

    // MARK: - Helpers

    private static func epochMillis(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1000)
    }

    /// Several YMCS models are decode-only -- they have no public memberwise
    /// initialiser, because nothing outside the client ever needs to build one.
    /// Rather than widen that API for a demo, the fixtures go through the real
    /// `Codable` path, which has the side benefit of exercising it.
    private static func decode<T: Decodable>(_ type: T.Type, _ object: [String: Any]) -> T? {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
