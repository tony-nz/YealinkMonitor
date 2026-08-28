import Foundation

/// One reply from the server: a three-digit code and the text that came with it.
public struct SMTPReply: Sendable, Equatable {
    public let code: Int
    public let lines: [String]

    public init(code: Int, lines: [String]) {
        self.code = code
        self.lines = lines
    }

    public var text: String { lines.joined(separator: " ") }
    public var isPositive: Bool { (200..<400).contains(code) }
}

public enum SMTPError: Error, Sendable {
    case notConfigured
    case connectionFailed(any Error)
    /// The connection closed or timed out mid-conversation.
    case connectionClosed
    /// A reply that was not a valid `NNN text` line.
    case malformedReply(String)
    /// The server said no. `command` never contains credentials.
    case rejected(command: String, reply: SMTPReply)
    /// STARTTLS was required but the server did not offer it. Sending anyway
    /// would put the password on the wire in the clear.
    case encryptionUnavailable
    /// The server offered no authentication method this client implements.
    case noSupportedAuthMethod
    case noRecipients
}

extension SMTPError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            "No mail server configured."
        case .connectionFailed(let error):
            "Could not reach the mail server: \(error.localizedDescription)"
        case .connectionClosed:
            "The mail server closed the connection."
        case .malformedReply(let line):
            "The mail server sent something unreadable: \(line)"
        case .rejected(let command, let reply):
            "The mail server rejected \(command): \(reply.code) \(reply.text)"
        case .encryptionUnavailable:
            "The mail server does not offer STARTTLS, so the password cannot be sent safely."
        case .noSupportedAuthMethod:
            "The mail server offers no login method this app supports (PLAIN or LOGIN)."
        case .noRecipients:
            "No recipient address."
        }
    }
}
