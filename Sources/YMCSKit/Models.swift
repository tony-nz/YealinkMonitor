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

    /// Compares Yealink firmware versions like `70.83.0.68`.
    ///
    /// Component-wise and numeric: a string comparison puts `70.9` after
    /// `70.83`, which would report most of a fleet as out of date.
    public static func isFirmware(_ lhs: String, olderThan rhs: String) -> Bool {
        let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a < b }
        }
        return false
    }

    /// Hex digits only, lowercased. YMCS is inconsistent about separators --
    /// `listDevices` returns `001565bbb1a9` and `listAlarms` may return
    /// `00:15:65:bb:b1:a9` -- so anything comparing MACs across endpoints has to
    /// go through this first.
    public static func normalizeMAC(_ mac: String) -> String {
        mac.filter(\.isHexDigit).lowercased()
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

    /// Still outstanding. YMCS keeps solved and ignored alarms in the same list,
    /// and `listAlarms` has no status filter, so the caller has to do this.
    public var isActive: Bool { status == .active }

    public var normalizedMAC: String? { mac.map(Device.normalizeMAC) }
}

// MARK: - Call quality

/// One call, as YMCS scored it. Answers the question the device list cannot: a
/// phone can be online continuously and still be unusable.
public struct CallRecord: Codable, Sendable, Hashable, Identifiable {
    public enum Quality: String, Sendable, Hashable, Codable {
        case good
        case poor
        case bad
        case unknown

        public init(rawValue: String) {
            switch rawValue.lowercased() {
            case "good": self = .good
            case "poor": self = .poor
            case "bad": self = .bad
            default: self = .unknown
            }
        }

        public var rawValue: String {
            switch self {
            case .good: "Good"
            case .poor: "Poor"
            case .bad: "Bad"
            case .unknown: "Unknown"
            }
        }

        public init(from decoder: any Decoder) throws {
            self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }

        public var isPoor: Bool { self == .poor || self == .bad }
    }

    public let id: String
    public let deviceName: String?
    public let mac: String?
    public let modelName: String?
    public let firmwareVersion: String?
    public let username: String?
    public let displayName: String?
    public let siteName: String?
    public let quality: Quality?
    public let startTime: Int64?
    public let endTime: Int64?
    /// Null in practice on every tenant seen so far, despite being documented.
    public let callerURI: String?
    public let calleeURI: String?
    /// The API document calls this milliseconds. It is not: a call from
    /// 1787874266000 to 1787874307000 -- 41 seconds -- reports `41`. Prefer
    /// `durationSeconds`, which derives the value from the timestamps and only
    /// falls back to this.
    public let duration: Int64?
    /// Mean Opinion Score, 1-5, per direction. Undocumented, and the only
    /// numeric quality measure the endpoint actually returns. 0 means the
    /// direction was not measured rather than "terrible".
    public let inConversationalMosAvg: Double?
    public let outConversationalMosAvg: Double?

    public var startDate: Date? {
        startTime.map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }

    public var endDate: Date? {
        endTime.map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }

    /// How long the call lasted.
    ///
    /// Derived from the timestamps where possible, because those are
    /// unambiguous, and the `duration` field's unit contradicts its
    /// documentation.
    public var durationSeconds: Int64? {
        if let startTime, let endTime, endTime > startTime {
            return (endTime - startTime) / 1000
        }
        return duration
    }

    /// The worse of the two directions, ignoring unmeasured ones.
    ///
    /// A call is only as good as its worse leg, and a zero means "not measured"
    /// -- averaging it in would report every one-way-measured call as unusable.
    public var mos: Double? {
        let measured = [inConversationalMosAvg, outConversationalMosAvg]
            .compactMap { $0 }
            .filter { $0 > 0 }
        return measured.min()
    }

    public var normalizedMAC: String? { mac.map(Device.normalizeMAC) }

    /// The SIP URIs are unreadable as-is: `"8195" <sip:8195@host:5061>`.
    public var caller: String? { Self.readableURI(callerURI) }
    public var callee: String? { Self.readableURI(calleeURI) }

    static func readableURI(_ uri: String?) -> String? {
        guard let uri else { return nil }
        guard let range = uri.range(of: "sip:") else { return uri }
        let rest = uri[range.upperBound...]
        let user = rest.prefix { $0 != "@" && $0 != ">" }
        return user.isEmpty ? uri : String(user)
    }
}

/// Fleet-wide call quality over a period.
public struct QualityStatistics: Codable, Sendable, Hashable {
    public let total: Int64
    public let badTotal: Int64?
    public let badPercentage: Double?
    public let goodPercentage: Double?

    public init(total: Int64, badTotal: Int64?, badPercentage: Double?, goodPercentage: Double?) {
        self.total = total
        self.badTotal = badTotal
        self.badPercentage = badPercentage
        self.goodPercentage = goodPercentage
    }
}

// MARK: - Operation log

/// An action taken in YMCS by anyone -- including this app.
///
/// Answers "did someone push config to this phone just before it started
/// dropping?", which nothing else in the API does.
public struct OperationLog: Codable, Sendable, Hashable, Identifiable {
    public var id: String {
        "\(createTime ?? 0)-\(operationObject ?? "")-\(operationType ?? "")"
    }

    public let module: String?
    public let operationType: String?
    public let operationObject: String?
    public let `operator`: String?
    public let ip: String?
    public let createTime: Int64?
    public let result: String?

    public var date: Date? {
        createTime.map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }

    private enum CodingKeys: String, CodingKey {
        case module, operationType, operationObject, `operator`, ip, createTime, result
        /// The API document's worked example spells it this way. Accepted so a
        /// server that matches the example still decodes.
        case operationTypetype
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        module = try container.decodeIfPresent(String.self, forKey: .module)
        operationType = try container.decodeIfPresent(String.self, forKey: .operationType)
            ?? container.decodeIfPresent(String.self, forKey: .operationTypetype)
        operationObject = try container.decodeIfPresent(String.self, forKey: .operationObject)
        `operator` = try container.decodeIfPresent(String.self, forKey: .operator)
        ip = try container.decodeIfPresent(String.self, forKey: .ip)
        createTime = try container.decodeIfPresent(Int64.self, forKey: .createTime)
        result = try container.decodeIfPresent(String.self, forKey: .result)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(module, forKey: .module)
        try container.encodeIfPresent(operationType, forKey: .operationType)
        try container.encodeIfPresent(operationObject, forKey: .operationObject)
        try container.encodeIfPresent(`operator`, forKey: .operator)
        try container.encodeIfPresent(ip, forKey: .ip)
        try container.encodeIfPresent(createTime, forKey: .createTime)
        try container.encodeIfPresent(result, forKey: .result)
    }

    public init(
        module: String? = nil,
        operationType: String? = nil,
        operationObject: String? = nil,
        operator: String? = nil,
        ip: String? = nil,
        createTime: Int64? = nil,
        result: String? = nil
    ) {
        self.module = module
        self.operationType = operationType
        self.operationObject = operationObject
        self.operator = `operator`
        self.ip = ip
        self.createTime = createTime
        self.result = result
    }

    /// YMCS returns i18n keys rather than text, e.g.
    /// `i18n.yiot.backend.operation.device.management.restart`. The last two
    /// segments are the only readable part.
    public static func readable(_ key: String?) -> String {
        guard let key, !key.isEmpty else { return "—" }
        guard key.hasPrefix("i18n.") else { return key }
        let parts = key.split(separator: ".").suffix(2).map(String.init)
        return parts.joined(separator: " ").capitalized
    }
}

// MARK: - Diagnostics

/// The handle YMCS returns when a diagnostic is started. Every diagnostic is
/// asynchronous: the request only asks the phone to do something, and the result
/// arrives later as a file.
public struct DiagnosticTicket: Codable, Sendable, Hashable {
    public let diagnosisId: String

    public init(diagnosisId: String) {
        self.diagnosisId = diagnosisId
    }
}

public struct DiagnosticStatus: Codable, Sendable, Hashable {
    public enum State: String, Sendable, Hashable, Codable {
        case inProgress
        case success
        case failure

        public init(rawValue: String) {
            switch rawValue.lowercased() {
            case "success": self = .success
            case "failure": self = .failure
            default: self = .inProgress
            }
        }

        public var rawValue: String {
            switch self {
            case .inProgress: "inprogress"
            case .success: "success"
            case .failure: "failure"
            }
        }

        public init(from decoder: any Decoder) throws {
            self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    public let deviceId: String?
    public let status: State
    /// A signed, expiring download link, present only once `status` is success.
    public let url: String?

    public init(deviceId: String?, status: State, url: String?) {
        self.deviceId = deviceId
        self.status = status
        self.url = url
    }

    public var downloadURL: URL? {
        guard status == .success, let url else { return nil }
        return URL(string: url)
    }
}

/// What a packet capture should record.
public enum PacketCaptureType: Int, Sendable, Hashable, CaseIterable {
    case custom = 0
    case signalling = 1
    case rtp = 2
    case notRTP = 3

    public var displayName: String {
        switch self {
        case .custom: "Custom filter"
        case .signalling: "SIP / H.245 / H.225"
        case .rtp: "RTP"
        case .notRTP: "Everything except RTP"
        }
    }
}

// MARK: - Accessories

/// A headset, expansion module, camera or speakerphone attached to a device.
public struct Accessory: Codable, Sendable, Hashable, Identifiable {
    /// YMCS reports this as an Integer from `listParts` on one device and as a
    /// String from the batch endpoint, for the same values.
    public enum ConnectionStatus: Sendable, Hashable, Codable {
        case notReported
        case offline
        case online
        case unknown(Int)

        public init(rawValue: Int) {
            switch rawValue {
            case -1: self = .notReported
            case 0: self = .offline
            case 1: self = .online
            default: self = .unknown(rawValue)
            }
        }

        public var rawValue: Int {
            switch self {
            case .notReported: -1
            case .offline: 0
            case .online: 1
            case .unknown(let value): value
            }
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Int.self) {
                self.init(rawValue: value)
                return
            }
            // The batch endpoint quotes it.
            let text = try container.decode(String.self)
            self.init(rawValue: Int(text) ?? 0)
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }

        /// An accessory that has never reported is not a fault -- it may simply
        /// have been added to YMCS and not plugged in yet.
        public var isProblem: Bool { self == .offline }
    }

    public let id: String
    /// The device it is attached to. Only the batch endpoint returns this; the
    /// per-device one does not need to.
    public let parentId: String?
    public let mac: String?
    public let sn: String?
    public let modelId: String?
    public let modelName: String?
    public let productType: String?
    /// "USB", "BT" and so on.
    public let connectWay: String?
    public let connStatus: ConnectionStatus?
    public let lanIp: String?
    public let programVersion: String?
    public let hardwareVersion: String?
    public let lastReportTime: Int64?

    public init(
        id: String,
        parentId: String? = nil,
        mac: String? = nil,
        sn: String? = nil,
        modelId: String? = nil,
        modelName: String? = nil,
        productType: String? = nil,
        connectWay: String? = nil,
        connStatus: ConnectionStatus? = nil,
        lanIp: String? = nil,
        programVersion: String? = nil,
        hardwareVersion: String? = nil,
        lastReportTime: Int64? = nil
    ) {
        self.id = id
        self.parentId = parentId
        self.mac = mac
        self.sn = sn
        self.modelId = modelId
        self.modelName = modelName
        self.productType = productType
        self.connectWay = connectWay
        self.connStatus = connStatus
        self.lanIp = lanIp
        self.programVersion = programVersion
        self.hardwareVersion = hardwareVersion
        self.lastReportTime = lastReportTime
    }

    public var displayName: String {
        if let modelName, !modelName.isEmpty { return modelName }
        if let productType, !productType.isEmpty { return productType }
        return mac.map(Device.formatMAC) ?? id
    }

    /// Attached but not working -- the case a device's own status hides.
    public var isProblem: Bool { connStatus?.isProblem ?? false }

    public var lastReportDate: Date? {
        lastReportTime.map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }
}

// MARK: - Device control

/// One device YMCS refused to act on, from the `errors[]` of a batch operation.
public struct OpError: Codable, Sendable, Hashable {
    /// The device id that failed, despite the name.
    public let field: String?
    public let msg: String?

    public init(field: String?, msg: String?) {
        self.field = field
        self.msg = msg
    }
}

/// The result of `POST /v2/dm/device/reboot`.
///
/// The endpoint answers 200 even when it rebooted nothing, so this shape is the
/// only place the truth appears. Callers must look at `failureCount` rather than
/// treating a non-throwing call as success.
///
/// (The API document's response table for reboot is copied from factory reset
/// and describes these fields as counting "factory restored devices". The field
/// names are what the server actually sends; the prose is wrong.)
public struct RebootResult: Codable, Sendable, Hashable {
    public let total: Int
    public let successCount: Int
    public let failureCount: Int
    public let errors: [OpError]?

    public init(total: Int, successCount: Int, failureCount: Int, errors: [OpError]? = nil) {
        self.total = total
        self.successCount = successCount
        self.failureCount = failureCount
        self.errors = errors
    }

    public static let empty = RebootResult(total: 0, successCount: 0, failureCount: 0, errors: nil)

    public var didFullySucceed: Bool { failureCount == 0 && successCount == total }

    /// Sums two chunk results, so a batch split across requests reports once.
    public func merging(_ other: RebootResult) -> RebootResult {
        RebootResult(
            total: total + other.total,
            successCount: successCount + other.successCount,
            failureCount: failureCount + other.failureCount,
            errors: {
                let combined = (errors ?? []) + (other.errors ?? [])
                return combined.isEmpty ? nil : combined
            }()
        )
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
