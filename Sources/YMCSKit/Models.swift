import Foundation

// MARK: - Device status

/// YMCS reports three distinct states. `pending` means the device is registered
/// in YMCS but has never phoned home -- typically never provisioned or never
/// powered on. Collapsing it into `offline` hides a different class of problem,
/// so it is kept separate throughout the app.
public enum DeviceStatus: Sendable, Hashable, Codable {
    case online
    case offline
    case pending
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue.lowercased() {
        case "online": self = .online
        case "offline": self = .offline
        case "pending": self = .pending
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .online: "online"
        case .offline: "offline"
        case .pending: "pending"
        case .unknown(let value): value
        }
    }

    /// The integer this status takes in `filter.deviceStatus` query parameters.
    /// `unknown` has no filter representation.
    public var filterValue: Int? {
        switch self {
        case .online: 1
        case .offline: 0
        case .pending: -1
        case .unknown: nil
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// SIP registration state of one line on a device. A device can be `online`
/// while its lines are unregistered -- arguably worse than being offline, since
/// the phone looks healthy but cannot take calls.
public enum AccountStatus: Int, Sendable, Hashable, Codable {
    case registered = 1
    case doNotDisturb = 2
    case unregistered = 3
    case unknown = 4

    public var isHealthy: Bool { self == .registered || self == .doNotDisturb }
}

public enum DeviceType: Int, Sendable, Hashable, Codable, CaseIterable {
    case phone = 1
    case room = 3

    public var displayName: String {
        switch self {
        case .phone: "Phone"
        case .room: "Room device"
        }
    }
}

// MARK: - Devices

/// A device as returned by `POST /v2/dm/listDevices`. Deliberately the lean
/// shape: the list endpoint returns only these fields, and the polling loop
/// fetches nothing more.
public struct Device: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let mac: String
    public let sn: String?
    public let name: String?
    public let modelId: String?
    public let siteId: String?
    public let programVersion: String?
    public let deviceStatus: DeviceStatus

    public init(
        id: String,
        mac: String,
        sn: String? = nil,
        name: String? = nil,
        modelId: String? = nil,
        siteId: String? = nil,
        programVersion: String? = nil,
        deviceStatus: DeviceStatus
    ) {
        self.id = id
        self.mac = mac
        self.sn = sn
        self.name = name
        self.modelId = modelId
        self.siteId = siteId
        self.programVersion = programVersion
        self.deviceStatus = deviceStatus
    }

    /// A human label, falling back to the MAC when the device is unnamed.
    public var displayName: String {
        if let name, !name.isEmpty { return name }
        return Self.formatMAC(mac)
    }

    /// YMCS returns MACs unpunctuated; colon-separate them for display.
    public static func formatMAC(_ mac: String) -> String {
        let bare = mac.filter { $0.isHexDigit }
        guard bare.count == 12 else { return mac }
        return stride(from: 0, to: 12, by: 2)
            .map { String(bare[bare.index(bare.startIndex, offsetBy: $0)...].prefix(2)) }
            .joined(separator: ":")
            .uppercased()
    }
}

public struct ReportAccount: Codable, Sendable, Hashable {
    public let accountId: String?
    public let lineId: Int?
    public let accountType: Int?
    public let accountServer: String?
    public let registerName: String?
    public let username: String?
    public let status: AccountStatus?
}

/// A device as returned by `GET /v2/dm/devices/{id}`, fetched lazily for the
/// detail pane only.
public struct DeviceDetail: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let mac: String
    public let sn: String?
    public let name: String?
    public let modelId: String?
    public let modelName: String?
    public let siteId: String?
    public let siteName: String?
    public let lanIp: String?
    public let deviceStatus: DeviceStatus
    public let programVersion: String?
    /// Epoch milliseconds. Tells you how stale YMCS's own view of the device is.
    public let lastReportTime: Int64?
    public let accounts: [ReportAccount]?

    public var lastReportDate: Date? {
        lastReportTime.map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }
}

// MARK: - Alarms

public struct Alarm: Codable, Sendable, Hashable, Identifiable {
    public enum Level: Int, Codable, Sendable, Hashable {
        case minor = 1
        case major = 2
        case critical = 3
    }

    public enum Status: Int, Codable, Sendable, Hashable {
        case active = 1
        case solved = 2
        case ignored = 3
    }

    public let id: String
    /// Free-text event name, e.g. "Offline".
    public let event: String?
    public let level: Level?
    public let mac: String?
    public let model: String?
    public let ip: String?
    public let siteName: String?
    public let status: Status?
    public let firstAlarmTime: Int64?
    public let lastAlarmTime: Int64?

    public var firstAlarmDate: Date? {
        firstAlarmTime.map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }

    public var lastAlarmDate: Date? {
        lastAlarmTime.map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }
}

// MARK: - Lookups

public struct Site: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String?
    public let parentId: String?
}

public struct DeviceModel: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String?
}

// MARK: - Paging

/// The envelope shared by every paginated YMCS endpoint.
public struct Page<Element: Codable & Sendable>: Codable, Sendable {
    public let skip: Int64?
    public let limit: Int64?
    public let total: Int64?
    public let data: [Element]?

    public var items: [Element] { data ?? [] }
}

public struct CountResponse: Codable, Sendable {
    public let total: Int64
}

/// Filter accepted by `POST /v2/dm/listDevices`.
public struct DeviceFilter: Codable, Sendable, Hashable {
    public var mac: String?
    public var modelId: String?
    public var deviceStatus: Int?
    public var accountStatus: Int?
    public var deviceType: Int?
    public var siteId: String?

    public init(
        mac: String? = nil,
        modelId: String? = nil,
        status: DeviceStatus? = nil,
        accountStatus: AccountStatus? = nil,
        deviceType: DeviceType? = nil,
        siteId: String? = nil
    ) {
        self.mac = mac
        self.modelId = modelId
        self.deviceStatus = status?.filterValue
        self.accountStatus = accountStatus?.rawValue
        self.deviceType = deviceType?.rawValue
        self.siteId = siteId
    }

    public var isEmpty: Bool {
        mac == nil && modelId == nil && deviceStatus == nil
            && accountStatus == nil && deviceType == nil && siteId == nil
    }
}
