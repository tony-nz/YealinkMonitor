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
/// Scope is deliberately read-only: this app monitors phones, it does not
/// reboot, reconfigure or factory-reset them. Adding a write path would mean
/// adding a confirmation story, so those endpoints are left out entirely.
public final class YMCSClient: Sendable {
    /// The API caps `listDevices` at 100 records per page.
    public static let maxPageSize = 100

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

    private func post<Response: Decodable & Sendable>(
        _ path: String,
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
        let data = try await executeRaw(method: "POST", path: path, query: [], body: encoded)
        return try decode(data)
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
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
