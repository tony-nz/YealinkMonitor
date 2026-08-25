import Foundation

/// The error body YMCS returns alongside a 4xx/5xx status.
public struct APIErrorBody: Codable, Sendable, Hashable {
    public struct Detail: Codable, Sendable, Hashable {
        public let field: String?
        public let message: String?
    }

    public let code: String?
    public let requestId: String?
    public let message: String?
    public let details: [Detail]?
}

public enum YMCSError: Error, Sendable {
    /// No Client ID / Secret has been configured yet.
    case notConfigured
    /// 401 from the token endpoint: the Client ID or Secret is wrong, or they
    /// belong to a different region.
    case authenticationFailed(APIErrorBody?)
    /// 403: authenticated, but this enterprise may not access the resource.
    case forbidden(APIErrorBody?)
    /// 400: malformed request. A bug in this client, not a user problem.
    case badRequest(APIErrorBody?)
    /// 404: no data matched.
    case notFound(APIErrorBody?)
    /// 429: rate limited. The API contract requires a minimum 30s backoff.
    case rateLimited(retryAfter: Duration)
    /// 5xx.
    case server(status: Int, APIErrorBody?)
    /// Anything else, including transport failures.
    case transport(any Error)
    /// The response was 2xx but could not be decoded.
    case decoding(any Error)

    /// Whether retrying the identical request could plausibly succeed.
    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .server, .transport: true
        case .notConfigured, .authenticationFailed, .forbidden,
             .badRequest, .notFound, .decoding: false
        }
    }
}

extension YMCSError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            "No YMCS credentials configured."
        case .authenticationFailed(let body):
            body?.message ?? "Authentication failed. Check the Client ID, Secret and region."
        case .forbidden(let body):
            body?.message ?? "This enterprise is not permitted to access that resource."
        case .badRequest(let body):
            body?.message ?? "The server rejected the request."
        case .notFound(let body):
            body?.message ?? "Not found."
        case .rateLimited(let retryAfter):
            "Rate limited by YMCS. Retrying in \(retryAfter.seconds)s."
        case .server(let status, let body):
            body?.message ?? "YMCS server error (HTTP \(status))."
        case .transport(let error):
            "Network error: \(error.localizedDescription)"
        case .decoding:
            "The server sent a response this app could not read."
        }
    }
}

extension Duration {
    var seconds: Int { Int(components.seconds) }
}
