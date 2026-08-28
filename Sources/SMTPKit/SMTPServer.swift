import Foundation

/// How the connection to the submission server is secured.
public enum SMTPEncryption: String, Sendable, Codable, CaseIterable {
    /// Connect in the clear, then upgrade with STARTTLS. Port 587.
    case startTLS
    /// TLS from the first byte. Port 465.
    case implicitTLS
    /// No encryption at all. Only sane for a relay on localhost.
    case none

    public var defaultPort: Int {
        switch self {
        case .startTLS: 587
        case .implicitTLS: 465
        case .none: 25
        }
    }

    public var displayName: String {
        switch self {
        case .startTLS: "STARTTLS"
        case .implicitTLS: "SSL/TLS"
        case .none: "None"
        }
    }
}

/// Where and how to submit mail. The password is deliberately not part of this
/// type: it is passed separately at send time so it can live in the keychain and
/// never be captured in a value that might be logged or persisted.
public struct SMTPServer: Sendable, Equatable, Codable {
    public var host: String
    public var port: Int
    public var encryption: SMTPEncryption
    public var username: String
    /// The name this client announces in EHLO. Servers rarely care, but sending
    /// a bare hostname that does not resolve is a small spam signal.
    public var clientName: String

    public init(
        host: String,
        port: Int? = nil,
        encryption: SMTPEncryption = .startTLS,
        username: String = "",
        clientName: String = "localhost"
    ) {
        self.host = host
        self.port = port ?? encryption.defaultPort
        self.encryption = encryption
        self.username = username
        self.clientName = clientName
    }

    public var isConfigured: Bool { !host.isEmpty && port > 0 }
}
