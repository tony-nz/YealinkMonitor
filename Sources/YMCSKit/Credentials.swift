import Foundation

public struct Credentials: Sendable, Hashable {
    public var clientID: String
    public var clientSecret: String
    public var region: Region

    public init(clientID: String, clientSecret: String, region: Region) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.region = region
    }

    /// `Basic base64(clientId:clientSecret)`, as the token endpoint requires.
    var basicAuthorization: String {
        let joined = "\(clientID):\(clientSecret)"
        let encoded = Data(joined.utf8).base64EncodedString()
        return "Basic \(encoded)"
    }

    public var isComplete: Bool {
        !clientID.isEmpty && !clientSecret.isEmpty
    }
}

/// Supplies credentials on demand. The Keychain-backed implementation lives in
/// the app target so this package stays free of Security framework and can be
/// tested without an entitlement or a login keychain.
public protocol CredentialsProviding: Sendable {
    func credentials() async throws -> Credentials
}

/// For tests and for driving the client from environment variables.
public struct StaticCredentialsProvider: CredentialsProviding {
    private let value: Credentials?

    public init(_ value: Credentials?) {
        self.value = value
    }

    /// Reads `YMCS_CLIENT_ID`, `YMCS_CLIENT_SECRET` and optionally
    /// `YMCS_REGION`, mirroring `Scripts/smoke-test.sh`.
    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let id = environment["YMCS_CLIENT_ID"],
              let secret = environment["YMCS_CLIENT_SECRET"],
              !id.isEmpty, !secret.isEmpty
        else {
            self.value = nil
            return
        }
        let region = environment["YMCS_REGION"].flatMap(Region.init(rawValue:)) ?? .au
        self.value = Credentials(clientID: id, clientSecret: secret, region: region)
    }

    public func credentials() async throws -> Credentials {
        guard let value, value.isComplete else { throw YMCSError.notConfigured }
        return value
    }
}
