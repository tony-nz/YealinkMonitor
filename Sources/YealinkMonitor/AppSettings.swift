import Foundation
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
        settings.mutedDeviceIDs = Set(defaults.stringArray(forKey: Key.muted) ?? [])
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
        defaults.set(Array(mutedDeviceIDs), forKey: Key.muted)
        if let deviceTypeFilter {
            defaults.set(deviceTypeFilter.rawValue, forKey: Key.deviceType)
        } else {
            defaults.removeObject(forKey: Key.deviceType)
        }
    }
}
