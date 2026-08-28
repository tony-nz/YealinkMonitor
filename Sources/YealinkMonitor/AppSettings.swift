import Foundation
import SMTPKit
import YMCSKit

/// User-visible settings, persisted in UserDefaults. The client secret is the
/// deliberate exception -- it lives in the keychain.
struct AppSettings: Equatable, Sendable {
    var clientID: String = ""
    var region: Region = .au
    /// Seconds between cheap heartbeat checks.
    var heartbeatSeconds: Int = 60
    /// Seconds between unconditional full device listings.
    var fullRefreshSeconds: Int = 600
    /// Consecutive polls before a device is reported offline.
    var confirmations: Int = 2
    var notificationsEnabled: Bool = true
    var notifyOnRecovery: Bool = true
    /// Suppress notifications between these hours (local time). Equal values
    /// disable quiet hours.
    var quietHoursStart: Int = 22
    var quietHoursEnd: Int = 7
    // MARK: - Email

    var emailEnabled: Bool = false
    /// Comma-separated in the UI, stored as a list.
    var emailRecipients: [String] = []
    var emailFrom: String = ""
    var smtpHost: String = ""
    var smtpPort: Int = SMTPEncryption.startTLS.defaultPort
    var smtpEncryption: SMTPEncryption = .startTLS
    var smtpUsername: String = ""
    /// Seconds to gather changes before sending, so one network fault produces
    /// one email rather than forty.
    var emailWindowSeconds: Int = 60
    /// Upper bound on emails in any rolling hour.
    var emailMaximumPerHour: Int = 12
    var emailOnRecovery: Bool = true
    /// Quiet hours exist to stop the Mac interrupting the person sitting at it.
    /// Email is the channel you actually want overnight, so by default it
    /// ignores them.
    var emailRespectsQuietHours: Bool = false

    var isEmailConfigured: Bool {
        !smtpHost.isEmpty && !emailFrom.isEmpty && !emailRecipients.isEmpty
    }

    var smtpServer: SMTPServer {
        SMTPServer(
            host: smtpHost,
            port: smtpPort,
            encryption: smtpEncryption,
            username: smtpUsername,
            clientName: Host.current().localizedName ?? "yealinkmonitor"
        )
    }

    var alertDigestConfiguration: AlertDigest.Configuration {
        var configuration = AlertDigest.Configuration()
        configuration.window = .seconds(max(0, emailWindowSeconds))
        configuration.maximumPerHour = max(1, emailMaximumPerHour)
        configuration.includesRecoveries = emailOnRecovery
        return configuration
    }

    // MARK: - Scheduled restarts

    var rebootSchedules: [RebootSchedule] = []
    /// How late an occurrence may be discovered and still run. Beyond this it is
    /// recorded as skipped: a restart hours after the time it was asked for is a
    /// surprise outage, not a helpful catch-up.
    var scheduleGraceMinutes: Int = 60

    /// How long after a reboot this app stops treating a device's drop as an
    /// outage. Long enough for a phone to boot and re-register, short enough
    /// that a phone which never comes back is still reported.
    var rebootSettlingSeconds: Int = 600
    /// Devices that are not in service -- a spare in a cupboard, a handset
    /// waiting to be returned. Distinct from a mute: muting says "stop telling
    /// me about this phone", archiving says "this phone is not part of the
    /// fleet", and the second one has to keep it out of counts, filters and
    /// bulk actions as well as out of alerts.
    var archivedDeviceIDs: Set<String> = []
    /// Devices the user has chosen not to be told about.
    var mutedDeviceIDs: Set<String> = []
    /// Restrict monitoring to one device type, or nil for everything.
    var deviceTypeFilter: DeviceType? = nil

    var isConfigured: Bool { !clientID.isEmpty }

    var quietHoursEnabled: Bool { quietHoursStart != quietHoursEnd }

    /// Quiet hours may wrap past midnight, which the naive comparison gets
    /// wrong for the common 22:00-07:00 case.
    func isQuietHour(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard quietHoursEnabled else { return false }
        let hour = calendar.component(.hour, from: date)
        if quietHoursStart < quietHoursEnd {
            return hour >= quietHoursStart && hour < quietHoursEnd
        }
        return hour >= quietHoursStart || hour < quietHoursEnd
    }

    var monitorConfiguration: Monitor.Configuration {
        var configuration = Monitor.Configuration()
        configuration.heartbeat = .seconds(max(15, heartbeatSeconds))
        configuration.fullRefresh = .seconds(max(heartbeatSeconds, fullRefreshSeconds))
        configuration.confirmations = max(1, confirmations)
        configuration.deviceType = deviceTypeFilter
        return configuration
    }
}

extension AppSettings {
    private enum Key {
        static let clientID = "clientID"
        static let region = "region"
        static let heartbeat = "heartbeatSeconds"
        static let fullRefresh = "fullRefreshSeconds"
        static let confirmations = "confirmations"
        static let notifications = "notificationsEnabled"
        static let notifyRecovery = "notifyOnRecovery"
        static let quietStart = "quietHoursStart"
        static let quietEnd = "quietHoursEnd"
        static let muted = "mutedDeviceIDs"
        static let archived = "archivedDeviceIDs"
        static let rebootSettling = "rebootSettlingSeconds"
        static let emailEnabled = "emailEnabled"
        static let emailRecipients = "emailRecipients"
        static let emailFrom = "emailFrom"
        static let smtpHost = "smtpHost"
        static let smtpPort = "smtpPort"
        static let smtpEncryption = "smtpEncryption"
        static let smtpUsername = "smtpUsername"
        static let emailWindow = "emailWindowSeconds"
        static let emailMaximumPerHour = "emailMaximumPerHour"
        static let emailOnRecovery = "emailOnRecovery"
        static let emailQuietHours = "emailRespectsQuietHours"
        static let schedules = "rebootSchedules"
        static let scheduleGrace = "scheduleGraceMinutes"
        static let deviceType = "deviceTypeFilter"
    }

    static func load(from defaults: UserDefaults = .standard) -> AppSettings {
        var settings = AppSettings()
        settings.clientID = defaults.string(forKey: Key.clientID) ?? ""
        if let raw = defaults.string(forKey: Key.region), let region = Region(rawValue: raw) {
            settings.region = region
        }
        if defaults.object(forKey: Key.heartbeat) != nil {
            settings.heartbeatSeconds = defaults.integer(forKey: Key.heartbeat)
        }
        if defaults.object(forKey: Key.fullRefresh) != nil {
            settings.fullRefreshSeconds = defaults.integer(forKey: Key.fullRefresh)
        }
        if defaults.object(forKey: Key.confirmations) != nil {
            settings.confirmations = defaults.integer(forKey: Key.confirmations)
        }
        if defaults.object(forKey: Key.notifications) != nil {
            settings.notificationsEnabled = defaults.bool(forKey: Key.notifications)
        }
        if defaults.object(forKey: Key.notifyRecovery) != nil {
            settings.notifyOnRecovery = defaults.bool(forKey: Key.notifyRecovery)
        }
        if defaults.object(forKey: Key.quietStart) != nil {
            settings.quietHoursStart = defaults.integer(forKey: Key.quietStart)
        }
        if defaults.object(forKey: Key.quietEnd) != nil {
            settings.quietHoursEnd = defaults.integer(forKey: Key.quietEnd)
        }
        if defaults.object(forKey: Key.rebootSettling) != nil {
            settings.rebootSettlingSeconds = defaults.integer(forKey: Key.rebootSettling)
        }
        settings.emailEnabled = defaults.bool(forKey: Key.emailEnabled)
        settings.emailRecipients = defaults.stringArray(forKey: Key.emailRecipients) ?? []
        settings.emailFrom = defaults.string(forKey: Key.emailFrom) ?? ""
        settings.smtpHost = defaults.string(forKey: Key.smtpHost) ?? ""
        if let raw = defaults.string(forKey: Key.smtpEncryption),
           let encryption = SMTPEncryption(rawValue: raw) {
            settings.smtpEncryption = encryption
        }
        settings.smtpPort = defaults.object(forKey: Key.smtpPort) != nil
            ? defaults.integer(forKey: Key.smtpPort)
            : settings.smtpEncryption.defaultPort
        settings.smtpUsername = defaults.string(forKey: Key.smtpUsername) ?? ""
        if defaults.object(forKey: Key.emailWindow) != nil {
            settings.emailWindowSeconds = defaults.integer(forKey: Key.emailWindow)
        }
        if defaults.object(forKey: Key.emailMaximumPerHour) != nil {
            settings.emailMaximumPerHour = defaults.integer(forKey: Key.emailMaximumPerHour)
        }
        if defaults.object(forKey: Key.emailOnRecovery) != nil {
            settings.emailOnRecovery = defaults.bool(forKey: Key.emailOnRecovery)
        }
        settings.emailRespectsQuietHours = defaults.bool(forKey: Key.emailQuietHours)
        if let data = defaults.data(forKey: Key.schedules) {
            // A schedule file this app cannot read must not stop it launching;
            // losing the schedules is better than losing the monitor.
            settings.rebootSchedules = (try? JSONDecoder().decode([RebootSchedule].self, from: data)) ?? []
        }
        if defaults.object(forKey: Key.scheduleGrace) != nil {
            settings.scheduleGraceMinutes = defaults.integer(forKey: Key.scheduleGrace)
        }
        settings.mutedDeviceIDs = Set(defaults.stringArray(forKey: Key.muted) ?? [])
        settings.archivedDeviceIDs = Set(defaults.stringArray(forKey: Key.archived) ?? [])
        if defaults.object(forKey: Key.deviceType) != nil {
            settings.deviceTypeFilter = DeviceType(rawValue: defaults.integer(forKey: Key.deviceType))
        }
        return settings
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(clientID, forKey: Key.clientID)
        defaults.set(region.rawValue, forKey: Key.region)
        defaults.set(heartbeatSeconds, forKey: Key.heartbeat)
        defaults.set(fullRefreshSeconds, forKey: Key.fullRefresh)
        defaults.set(confirmations, forKey: Key.confirmations)
        defaults.set(notificationsEnabled, forKey: Key.notifications)
        defaults.set(notifyOnRecovery, forKey: Key.notifyRecovery)
        defaults.set(quietHoursStart, forKey: Key.quietStart)
        defaults.set(quietHoursEnd, forKey: Key.quietEnd)
        defaults.set(rebootSettlingSeconds, forKey: Key.rebootSettling)
        defaults.set(emailEnabled, forKey: Key.emailEnabled)
        defaults.set(emailRecipients, forKey: Key.emailRecipients)
        defaults.set(emailFrom, forKey: Key.emailFrom)
        defaults.set(smtpHost, forKey: Key.smtpHost)
        defaults.set(smtpPort, forKey: Key.smtpPort)
        defaults.set(smtpEncryption.rawValue, forKey: Key.smtpEncryption)
        defaults.set(smtpUsername, forKey: Key.smtpUsername)
        defaults.set(emailWindowSeconds, forKey: Key.emailWindow)
        defaults.set(emailMaximumPerHour, forKey: Key.emailMaximumPerHour)
        defaults.set(emailOnRecovery, forKey: Key.emailOnRecovery)
        defaults.set(emailRespectsQuietHours, forKey: Key.emailQuietHours)
        if let data = try? JSONEncoder().encode(rebootSchedules) {
            defaults.set(data, forKey: Key.schedules)
        }
        defaults.set(scheduleGraceMinutes, forKey: Key.scheduleGrace)
        defaults.set(Array(mutedDeviceIDs), forKey: Key.muted)
        defaults.set(Array(archivedDeviceIDs), forKey: Key.archived)
        if let deviceTypeFilter {
            defaults.set(deviceTypeFilter.rawValue, forKey: Key.deviceType)
        } else {
            defaults.removeObject(forKey: Key.deviceType)
        }
    }
}
