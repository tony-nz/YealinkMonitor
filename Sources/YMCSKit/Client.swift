import Foundation

extension YMCSError {
    /// Maps a non-2xx response onto the documented status codes.
    static func from(
        _ response: HTTPResponse,
        treating401As unauthorized: (APIErrorBody?) -> YMCSError = YMCSError.authenticationFailed
    ) -> YMCSError {
        let body = try? JSONDecoder().decode(APIErrorBody.self, from: response.body)
        switch response.status {
        case 400: return .badRequest(body)
        case 401: return unauthorized(body)
        case 403: return .forbidden(body)
        case 404: return .notFound(body)
        case 429: return .rateLimited(retryAfter: retryAfter(from: response))
        case 500...599: return .server(status: response.status, body)
        default: return .server(status: response.status, body)
        }
    }

    /// The API mandates a 30s floor, so a shorter `Retry-After` is ignored.
    static func retryAfter(from response: HTTPResponse) -> Duration {
        guard let raw = response.header("Retry-After"), let seconds = Double(raw) else {
            return .seconds(30)
        }
        return max(.seconds(seconds), .seconds(30))
    }
}

/// Typed access to the YMCS Open API v2.
///
/// Reboot is the only write this client can perform. Factory reset
/// (`POST /v2/dm/device/reset`, and `parts/reset` for accessories) is
/// deliberately absent: it differs from reboot by one path segment and takes an
/// identical body, so the protection against firing it by accident is that no
/// code here can express it. Do not add a general `deviceControl(action:)`
/// helper -- the separation is the point.
///
/// Configuration and firmware push are likewise not implemented.
public final class YMCSClient: Sendable {
    /// The API caps `listDevices` at 100 records per page.
    public static let maxPageSize = 100
    /// `listAlarms` allows 500, and alarms are small.
    public static let maxAlarmPageSize = 500

    private let transport: any HTTPTransport
    private let credentialsProvider: any CredentialsProviding
    private let tokenStore: TokenStore
    private let rateLimiter: RateLimiter

    public init(
        transport: any HTTPTransport = URLSessionTransport.makeDefault(),
        credentialsProvider: any CredentialsProviding,
        rateLimiter: RateLimiter = RateLimiter()
    ) {
        self.transport = transport
        self.credentialsProvider = credentialsProvider
        self.tokenStore = TokenStore(
            transport: transport,
            credentialsProvider: credentialsProvider
        )
        self.rateLimiter = rateLimiter
    }

    // MARK: - Devices

    /// One page of devices. `autoCount` should be true only for the first page:
    /// the server counts the whole result set to answer it.
    public func listDevices(
        skip: Int = 0,
        limit: Int = maxPageSize,
        autoCount: Bool = true,
        filter: DeviceFilter? = nil
    ) async throws -> Page<Device> {
        struct Body: Encodable {
            let skip: Int
            let limit: Int
            let autoCount: Bool
            let filter: DeviceFilter?
        }
        let body = Body(
            skip: skip,
            limit: min(limit, Self.maxPageSize),
            autoCount: autoCount,
            filter: (filter?.isEmpty ?? true) ? nil : filter
        )
        return try await post("/v2/dm/listDevices", body: body)
    }

    /// Every device, paginated. This is the expensive call: roughly one request
    /// per 100 devices, so the poller uses `deviceCount` as a heartbeat and
    /// only reaches for this when something has actually changed.
    public func allDevices(filter: DeviceFilter? = nil) async throws -> [Device] {
        var collected: [Device] = []
        var skip = 0
        // Bounds the loop if the server ever reports an inconsistent total.
        let hardLimit = 20_000

        while collected.count < hardLimit {
            let page = try await listDevices(
                skip: skip,
                limit: Self.maxPageSize,
                autoCount: skip == 0,
                filter: filter
            )
            let items = page.items
            collected.append(contentsOf: items)
            if items.count < Self.maxPageSize { break }
            skip += items.count
            if let total = page.total, Int64(collected.count) >= total { break }
        }
        return collected
    }

    /// `GET /v2/dm/statistics/deviceCount`. One cheap request; the basis of the
    /// polling heartbeat.
    public func deviceCount(
        status: DeviceStatus? = nil,
        type: DeviceType? = nil
    ) async throws -> Int64 {
        var query: [URLQueryItem] = []
        if let value = status?.filterValue {
            query.append(URLQueryItem(name: "deviceStatus", value: String(value)))
        }
        if let type {
            query.append(URLQueryItem(name: "deviceType", value: String(type.rawValue)))
        }
        let response: CountResponse = try await get("/v2/dm/statistics/deviceCount", query: query)
        return response.total
    }

    /// Full detail for one device, including LAN IP, last report time and
    /// per-line SIP registration state. Fetched lazily for the detail pane.
    public func device(id: String, select: [String] = []) async throws -> DeviceDetail {
        let query = select.isEmpty ? [] : [URLQueryItem(name: "select", value: select.joined(separator: ","))]
        return try await get("/v2/dm/devices/\(id)", query: query)
    }

    // MARK: - Device control

    /// `POST /v2/dm/device/reboot`. Restarts phones through YMCS.
    ///
    /// Three things this does not do, all of which the caller must handle:
    ///
    ///   - It does not reach offline phones. YMCS accepts the request and the
    ///     device never sees it, and that still counts as a success here.
    ///   - It does not fail loudly. A partial failure is a 200 with the detail
    ///     in `errors[]`, so `RebootResult.didFullySucceed` is the check that
    ///     matters, not the absence of a thrown error.
    ///   - It does not wait. The phones drop shortly afterwards and take a
    ///     minute or two to come back, which looks exactly like an outage to
    ///     anything watching -- see `Monitor.reboot`.
    ///
    /// The documented cap is 200 ids per call; this chunks at 100 to match the
    /// paging used everywhere else.
    public func rebootDevices(
        ids: [String],
        deviceType: DeviceType = .phone
    ) async throws -> RebootResult {
        struct Body: Encodable {
            let deviceIds: [String]
            let deviceType: Int
        }
        // Duplicates would be counted twice by the server's own totals.
        var seen = Set<String>()
        let unique = ids.filter { seen.insert($0).inserted }
        guard !unique.isEmpty else { return .empty }

        var result = RebootResult.empty
        for chunk in stride(from: 0, to: unique.count, by: Self.maxPageSize).map({
            Array(unique[$0..<min($0 + Self.maxPageSize, unique.count)])
        }) {
            let chunkResult: RebootResult = try await post(
                "/v2/dm/device/reboot",
                body: Body(deviceIds: chunk, deviceType: deviceType.rawValue)
            )
            result = result.merging(chunkResult)
        }
        return result
    }

    /// `POST /v2/dm/devices/{deviceId}/parts/reboot`. Restarts accessories on
    /// one device; passing no ids restarts all of them.
    ///
    /// Same batch semantics as `rebootDevices` -- a partial failure is a 200.
    public func rebootAccessories(
        deviceID: String,
        partIDs: [String] = []
    ) async throws -> RebootResult {
        struct Body: Encodable {
            let partIds: [String]?
        }
        return try await post(
            "/v2/dm/devices/\(deviceID)/parts/reboot",
            body: Body(partIds: partIDs.isEmpty ? nil : partIDs)
        )
    }

    // MARK: - Diagnostics

    /// Which network ports this device can capture on, e.g. `["wan", "wlan0"]`.
    public func networkInterfaces(deviceID: String) async throws -> [String] {
        let data = try await executeRaw(
            method: "GET",
            path: "/v2/dm/devices/\(deviceID)/networkInterfaces",
            query: [],
            body: nil
        )
        return try decode([String].self, from: data)
    }

    /// Asks the phone for a screenshot. Returns a ticket, not a picture.
    public func startScreenshot(deviceID: String) async throws -> DiagnosticTicket {
        try await put("/v2/dm/devices/\(deviceID)/captureScreen", body: EmptyBody())
    }

    public func startSyslogExport(deviceID: String) async throws -> DiagnosticTicket {
        try await put("/v2/dm/devices/\(deviceID)/exportSyslog", body: EmptyBody())
    }

    public func startConfigExport(deviceID: String) async throws -> DiagnosticTicket {
        try await put("/v2/dm/devices/\(deviceID)/exportConfig", body: EmptyBody())
    }

    /// Pings from the phone, not from this Mac. That is the whole point: it
    /// answers "can the handset reach its gateway", which nothing on this
    /// machine can tell you.
    public func startPing(
        deviceID: String,
        host: String,
        times: Int
    ) async throws -> DiagnosticTicket {
        try await put(
            "/v2/dm/devices/\(deviceID)/ping",
            body: HostProbe(host: host, times: Self.clampedProbeCount(times))
        )
    }

    public func startTraceroute(
        deviceID: String,
        host: String,
        times: Int = 1
    ) async throws -> DiagnosticTicket {
        try await put(
            "/v2/dm/devices/\(deviceID)/traceroute",
            body: HostProbe(host: host, times: Self.clampedProbeCount(times))
        )
    }

    /// Duration is clamped to the documented 180-3600s range: the server rejects
    /// anything outside it, and a rejection here costs a round trip to learn
    /// something the caller could have been told immediately.
    public func startPacketCapture(
        deviceID: String,
        networkInterface: String = "wan",
        type: PacketCaptureType = .notRTP,
        filter: String? = nil,
        duration: Int = 180
    ) async throws -> DiagnosticTicket {
        struct Body: Encodable {
            let networkInterface: String
            let type: Int
            let filter: String?
            let duration: Int
        }
        return try await put(
            "/v2/dm/devices/\(deviceID)/startPacketCapture",
            body: Body(
                networkInterface: networkInterface,
                type: type.rawValue,
                filter: type == .custom ? filter : nil,
                duration: min(3600, max(180, duration))
            )
        )
    }

    /// Ends a capture early. The file is available through the same ticket.
    public func stopPacketCapture(deviceID: String) async throws {
        _ = try await executeRaw(
            method: "PUT",
            path: "/v2/dm/devices/\(deviceID)/stopPacketCapture",
            query: [],
            body: nil
        )
    }

    public func diagnosticStatus(id: String) async throws -> DiagnosticStatus {
        try await get("/v2/dm/diagnosis/\(id)/status")
    }

    /// Polls a diagnostic to completion.
    ///
    /// Every diagnostic in the API works this way, so the waiting is written
    /// once here rather than six times in the UI. The timeout is generous
    /// because a packet capture legitimately runs for minutes -- but it is not
    /// unbounded, since a phone that goes offline mid-diagnostic never reports
    /// anything and the caller would otherwise wait forever.
    public func awaitDiagnostic(
        id: String,
        pollInterval: Duration = .seconds(3),
        timeout: Duration = .seconds(300)
    ) async throws -> DiagnosticStatus {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            let status = try await diagnosticStatus(id: id)
            if status.status != .inProgress { return status }
            if ContinuousClock.now >= deadline {
                throw YMCSError.diagnosticTimedOut(id: id)
            }
            try await Task.sleep(for: pollInterval)
        }
    }

    private static func clampedProbeCount(_ times: Int) -> Int {
        min(30, max(1, times))
    }

    private struct HostProbe: Encodable {
        let host: String
        let times: Int
    }

    /// Several diagnostics are `PUT` with no body at all; YMCS is happy with an
    /// empty object and unhappy with a missing Content-Type.
    private struct EmptyBody: Encodable {}

    // MARK: - Accessories

    /// `POST /v2/dm/device/listParts`. Accessories for many devices at once.
    ///
    /// The response is a bare array rather than the usual page envelope, and
    /// `connStatus` arrives as a quoted string here but as a number from the
    /// per-device endpoint. Both are handled in `Accessory`.
    public func accessories(forDeviceIDs ids: [String]) async throws -> [Accessory] {
        struct Body: Encodable {
            let deviceIds: [String]
        }
        guard !ids.isEmpty else { return [] }

        var collected: [Accessory] = []
        // Documented cap is 200; chunked at 100 like everything else here.
        for start in stride(from: 0, to: ids.count, by: Self.maxPageSize) {
            let chunk = Array(ids[start..<min(start + Self.maxPageSize, ids.count)])
            let data = try await executeRaw(
                method: "POST",
                path: "/v2/dm/device/listParts",
                query: [],
                body: try JSONEncoder().encode(Body(deviceIds: chunk))
            )
            collected.append(contentsOf: try decode([Accessory].self, from: data))
        }
        return collected
    }

    /// `POST /v2/dm/devices/{deviceId}/listParts`. One device, paged.
    public func accessories(
        deviceID: String,
        skip: Int = 0,
        limit: Int = 100
    ) async throws -> Page<Accessory> {
        struct Body: Encodable {
            let skip: Int
            let limit: Int
            let autoCount: Bool
        }
        return try await post(
            "/v2/dm/devices/\(deviceID)/listParts",
            body: Body(skip: skip, limit: limit, autoCount: true)
        )
    }

    // MARK: - Alarms

    /// `POST /v2/dm/listAlarms`. YMCS raises an "Offline" alarm with its own
    /// timestamps, which is more trustworthy than inferring a drop time from
    /// when this app happened to poll.
    public func listAlarms(
        skip: Int = 0,
        limit: Int = 100,
        autoCount: Bool = true,
        mac: String? = nil,
        deviceType: DeviceType? = nil
    ) async throws -> Page<Alarm> {
        struct Filter: Encodable {
            let mac: String?
            let deviceType: Int?
        }
        struct Body: Encodable {
            let skip: Int
            let limit: Int
            let autoCount: Bool
            let filter: Filter?
        }
        let filter = (mac == nil && deviceType == nil)
            ? nil
            : Filter(mac: mac, deviceType: deviceType?.rawValue)
        return try await post(
            "/v2/dm/listAlarms",
            body: Body(skip: skip, limit: limit, autoCount: autoCount, filter: filter)
        )
    }

    /// Every alarm YMCS is currently holding, paged at the documented maximum.
    ///
    /// `listAlarms` has no status filter, so solved and ignored alarms come back
    /// alongside active ones and are filtered by the caller. The cap exists
    /// because an enterprise that has never triaged an alarm can accumulate
    /// thousands, and this runs on a poll loop.
    public func allAlarms(
        deviceType: DeviceType? = nil,
        maximum: Int = 2_000
    ) async throws -> (alarms: [Alarm], total: Int64?) {
        var collected: [Alarm] = []
        var total: Int64?
        var skip = 0

        while collected.count < maximum {
            let page = try await listAlarms(
                skip: skip,
                limit: Self.maxAlarmPageSize,
                autoCount: skip == 0,
                deviceType: deviceType
            )
            if skip == 0 { total = page.total }
            let items = page.items
            collected.append(contentsOf: items)
            if items.count < Self.maxAlarmPageSize { break }
            skip += items.count
            if let total, Int64(collected.count) >= total { break }
        }
        return (collected, total)
    }

    // MARK: - Call quality

    /// `POST /v2/dm/listQoes`. Call records, newest first as YMCS returns them.
    public func listCalls(
        skip: Int = 0,
        limit: Int = 100,
        autoCount: Bool = true,
        mac: String? = nil,
        siteIDs: [String] = [],
        since: Date? = nil,
        until: Date? = nil
    ) async throws -> Page<CallRecord> {
        struct Filter: Encodable {
            let mac: String?
            let siteIds: [String]?
            let startTime: Int64?
            let endTime: Int64?

            var isEmpty: Bool {
                mac == nil && siteIds == nil && startTime == nil && endTime == nil
            }
        }
        struct Body: Encodable {
            let skip: Int
            let limit: Int
            let autoCount: Bool
            let filter: Filter?
        }
        let filter = Filter(
            mac: mac,
            siteIds: siteIDs.isEmpty ? nil : siteIDs,
            startTime: since.map(Self.milliseconds),
            endTime: until.map(Self.milliseconds)
        )
        return try await post(
            "/v2/dm/listQoes",
            body: Body(
                skip: skip,
                limit: min(limit, Self.maxAlarmPageSize),
                autoCount: autoCount,
                filter: filter.isEmpty ? nil : filter
            )
        )
    }

    /// `POST /v2/dm/statistics/qoe`. A start and end time only count if both are
    /// given, so they are sent as a pair or not at all.
    public func callQualityStatistics(
        siteIDs: [String] = [],
        since: Date? = nil,
        until: Date? = nil
    ) async throws -> QualityStatistics {
        struct Body: Encodable {
            let siteIds: [String]?
            let startTime: Int64?
            let endTime: Int64?
        }
        let bounded = since != nil && until != nil
        return try await post(
            "/v2/dm/statistics/qoe",
            body: Body(
                siteIds: siteIDs.isEmpty ? nil : siteIDs,
                startTime: bounded ? since.map(Self.milliseconds) : nil,
                endTime: bounded ? until.map(Self.milliseconds) : nil
            )
        )
    }

    // MARK: - Operation log

    /// `POST /v2/dm/listOpLogs`. Everything anyone did in YMCS, this app
    /// included -- the independent record of our own restarts.
    public func listOperationLogs(
        skip: Int = 0,
        limit: Int = 100,
        autoCount: Bool = true,
        since: Date? = nil,
        until: Date? = nil
    ) async throws -> Page<OperationLog> {
        struct Filter: Encodable {
            let startTime: Int64?
            let endTime: Int64?
        }
        struct Body: Encodable {
            let skip: Int
            let limit: Int
            let autoCount: Bool
            // Documented as required, unlike every other list endpoint here.
            let filter: Filter
        }
        return try await post(
            "/v2/dm/listOpLogs",
            body: Body(
                skip: skip,
                limit: min(limit, Self.maxAlarmPageSize),
                autoCount: autoCount,
                filter: Filter(
                    startTime: since.map(Self.milliseconds),
                    endTime: until.map(Self.milliseconds)
                )
            )
        )
    }

    static func milliseconds(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1000)
    }

    // MARK: - Lookups

    public func listSites(skip: Int = 0, limit: Int = 100) async throws -> Page<Site> {
        struct Body: Encodable {
            let skip: Int
            let limit: Int
            let autoCount: Bool
        }
        return try await post("/v2/dm/listSites", body: Body(skip: skip, limit: limit, autoCount: true))
    }

    /// Model id -> name, so the UI can show "SIP-T54S" instead of a UUID.
    /// The documented response shape is `{"data": [...]}` but the worked example
    /// in the same document returns a bare array, so both are accepted.
    public func models(deviceType: DeviceType) async throws -> [DeviceModel] {
        let data = try await executeRaw(
            method: "GET",
            path: "/v2/dm/models",
            query: [URLQueryItem(name: "deviceType", value: String(deviceType.rawValue))],
            body: nil
        )
        let decoder = JSONDecoder()
        if let bare = try? decoder.decode([DeviceModel].self, from: data) { return bare }
        do {
            return try decoder.decode(Page<DeviceModel>.self, from: data).items
        } catch {
            throw YMCSError.decoding(error)
        }
    }

    // MARK: - Connectivity

    /// Obtains a token and reads a single device, proving the credentials and
    /// region are correct. Mirrors `Scripts/smoke-test.sh`.
    public func verifyConnection() async throws {
        _ = try await listDevices(skip: 0, limit: 1, autoCount: false)
    }

    /// How long the rate limiter is currently holding requests back, if at all.
    public func currentCooldown() async -> Duration? {
        await rateLimiter.remainingCooldown
    }

    // MARK: - Plumbing

    private func get<Response: Decodable & Sendable>(
        _ path: String,
        query: [URLQueryItem] = []
    ) async throws -> Response {
        let data = try await executeRaw(method: "GET", path: path, query: query, body: nil)
        return try decode(data)
    }

    private func put<Response: Decodable & Sendable>(
        _ path: String,
        body: some Encodable
    ) async throws -> Response {
        try await send(method: "PUT", path: path, body: body)
    }

    private func post<Response: Decodable & Sendable>(
        _ path: String,
        body: some Encodable
    ) async throws -> Response {
        try await send(method: "POST", path: path, body: body)
    }

    private func send<Response: Decodable & Sendable>(
        method: String,
        path: String,
        body: some Encodable
    ) async throws -> Response {
        let encoded: Data
        do {
            let encoder = JSONEncoder()
            // Omitting nils matters: sending `"filter": null` is not the same
            // as omitting the key for some YMCS endpoints.
            encoded = try encoder.encode(body)
        } catch {
            throw YMCSError.decoding(error)
        }
        let data = try await executeRaw(method: method, path: path, query: [], body: encoded)
        return try decode(data)
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        try decode(T.self, from: data)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw YMCSError.decoding(error)
        }
    }

    private func executeRaw(
        method: String,
        path: String,
        query: [URLQueryItem],
        body: Data?
    ) async throws -> Data {
        // One retry only, and only for a 401: a token can legitimately expire
        // between the staleness check and the request landing. Anything else
        // that fails twice will keep failing.
        var forceRefresh = false
        for attempt in 0...1 {
            let credentials = try await credentialsProvider.credentials()
            let token = try await tokenStore.accessToken(forceRefresh: forceRefresh)

            var components = URLComponents(
                url: credentials.region.baseURL.appending(path: path),
                resolvingAgainstBaseURL: false
            )!
            if !query.isEmpty { components.queryItems = query }
            guard let url = components.url else { throw YMCSError.badRequest(nil) }

            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            RequestSigner.sign(&request)
            if let body {
                request.httpBody = body
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }

            let delay = await rateLimiter.reserve()
            if delay > .zero {
                try await Task.sleep(for: delay)
            }

            let response: HTTPResponse
            do {
                response = try await transport.send(request)
            } catch {
                throw YMCSError.transport(error)
            }

            switch response.status {
            case 200...299:
                return response.body
            case 401 where attempt == 0:
                await tokenStore.invalidate()
                forceRefresh = true
                continue
            case 429:
                let retryAfter = YMCSError.retryAfter(from: response)
                await rateLimiter.noteRateLimited(retryAfter: retryAfter)
                throw YMCSError.rateLimited(retryAfter: retryAfter)
            default:
                throw YMCSError.from(response)
            }
        }
        throw YMCSError.authenticationFailed(nil)
    }
}
