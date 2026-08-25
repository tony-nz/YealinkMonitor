import Foundation

/// Holds the OAuth2 access token and refreshes it before expiry.
///
/// Concurrent callers that arrive while a refresh is in flight join the same
/// refresh rather than each starting their own -- important because YMCS issues
/// exactly one Client ID/Secret pair per enterprise, and hammering the token
/// endpoint from several poll tasks is a good way to get rate limited.
public actor TokenStore {
    /// Refresh once this fraction of the token's lifetime has elapsed, so a
    /// request is never sent with a token that expires mid-flight.
    private static let refreshThreshold = 0.8
    /// Used when the server omits `expires_in`.
    private static let fallbackLifetime: TimeInterval = 3600

    private struct Token {
        var value: String
        var expiresAt: Date
        var refreshAt: Date
    }

    private let transport: any HTTPTransport
    private let credentialsProvider: any CredentialsProviding
    private let now: @Sendable () -> Date

    private var token: Token?
    private var inFlight: Task<String, any Error>?

    public init(
        transport: any HTTPTransport,
        credentialsProvider: any CredentialsProviding,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.credentialsProvider = credentialsProvider
        self.now = now
    }

    /// Returns a usable access token, fetching or refreshing as needed.
    public func accessToken(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh, let token, now() < token.refreshAt {
            return token.value
        }
        if let inFlight {
            return try await inFlight.value
        }
        let task = Task<String, any Error> { [self] in
            try await fetchToken()
        }
        inFlight = task
        defer { inFlight = nil }
        do {
            return try await task.value
        } catch {
            // A failed refresh must not leave a stale token in place; the next
            // caller should retry rather than send a token we know is bad.
            if forceRefresh { token = nil }
            throw error
        }
    }

    /// Discards the cached token. Call after a 401 on a business request.
    public func invalidate() {
        token = nil
    }

    private func fetchToken() async throws -> String {
        let credentials = try await credentialsProvider.credentials()
        var request = URLRequest(url: credentials.region.baseURL.appending(path: "/v2/token"))
        request.httpMethod = "POST"
        request.setValue(credentials.basicAuthorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        RequestSigner.sign(&request)
        request.httpBody = Data("grant_type=client_credentials".utf8)

        let response: HTTPResponse
        do {
            response = try await transport.send(request)
        } catch {
            throw YMCSError.transport(error)
        }

        guard response.status == 200 else {
            throw YMCSError.from(response)
        }

        struct TokenResponse: Decodable {
            let access_token: String
            let token_type: String?
            let expires_in: Double?
        }

        let decoded: TokenResponse
        do {
            decoded = try JSONDecoder().decode(TokenResponse.self, from: response.body)
        } catch {
            throw YMCSError.decoding(error)
        }

        let lifetime = decoded.expires_in ?? Self.fallbackLifetime
        let issuedAt = now()
        token = Token(
            value: decoded.access_token,
            expiresAt: issuedAt.addingTimeInterval(lifetime),
            refreshAt: issuedAt.addingTimeInterval(lifetime * Self.refreshThreshold)
        )
        return decoded.access_token
    }
}

/// Every YMCS request -- token and business alike -- must carry a millisecond
/// timestamp and a nonce of at most 32 characters.
enum RequestSigner {
    static func sign(_ request: inout URLRequest, now: Date = Date()) {
        let milliseconds = Int64((now.timeIntervalSince1970 * 1000).rounded())
        request.setValue(String(milliseconds), forHTTPHeaderField: "timestamp")
        request.setValue(nonce(), forHTTPHeaderField: "nonce")
    }

    /// A UUID with the hyphens removed is exactly 32 characters.
    static func nonce() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }
}
