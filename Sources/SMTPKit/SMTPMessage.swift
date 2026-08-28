import Foundation

/// A plain-text message. Multipart, attachments and HTML are out of scope: this
/// exists to deliver outage alerts, and every one of those is a short paragraph.
public struct SMTPMessage: Sendable, Equatable {
    public var from: String
    public var fromName: String?
    public var to: [String]
    public var subject: String
    public var body: String

    public init(
        from: String,
        fromName: String? = nil,
        to: [String],
        subject: String,
        body: String
    ) {
        self.from = from
        self.fromName = fromName
        self.to = to
        self.subject = subject
        self.body = body
    }

    /// The RFC 5322 message, ready to hand to DATA.
    ///
    /// The headers are not decoration. Mail with no `Date`, no `Message-ID` or a
    /// `From` that does not match the envelope is filed as spam by most
    /// receivers, which for an alerting system is the same as not sending it.
    ///
    /// - Parameters:
    ///   - date: injected so the output is testable.
    ///   - messageID: injected for the same reason; generated per message.
    public func rendered(date: Date, messageID: String) -> String {
        var headers: [String] = []
        headers.append("Date: \(Self.rfc5322Date(date))")
        headers.append("From: \(Self.address(from, name: fromName))")
        headers.append("To: \(to.map { Self.address($0, name: nil) }.joined(separator: ", "))")
        headers.append("Subject: \(Self.encodedHeaderValue(subject))")
        headers.append("Message-ID: <\(messageID)>")
        headers.append("MIME-Version: 1.0")
        headers.append("Content-Type: text/plain; charset=utf-8")
        // Quoted-printable rather than base64: an alert that a human might read
        // in a raw form stays readable, and base64 text/plain scores worse with
        // spam filters.
        headers.append("Content-Transfer-Encoding: quoted-printable")
        headers.append("Auto-Submitted: auto-generated")

        let normalisedBody = body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return headers.joined(separator: "\r\n")
            + "\r\n\r\n"
            + Self.quotedPrintable(normalisedBody)
    }

    /// A default Message-ID domain taken from the sender, so it matches the
    /// From header rather than inventing a hostname.
    public var messageIDDomain: String {
        let parts = from.split(separator: "@")
        // An address with no domain part would otherwise produce a Message-ID
        // with no domain at all, which is not a valid Message-ID.
        guard parts.count == 2, !parts[1].isEmpty else { return "localhost" }
        return String(parts[1])
    }

    // MARK: - Encoding

    static func address(_ address: String, name: String?) -> String {
        guard let name, !name.isEmpty else { return "<\(address)>" }
        return "\(encodedHeaderValue(name, forcePhrase: true)) <\(address)>"
    }

    /// RFC 2047 encoding, applied only when needed. A site called "Wellington"
    /// stays readable; one with a macron does not become mojibake.
    static func encodedHeaderValue(_ value: String, forcePhrase: Bool = false) -> String {
        let isPlainASCII = value.allSatisfy { $0.isASCII && !$0.isNewline }
        if isPlainASCII {
            // A phrase containing specials must be quoted, per RFC 5322.
            if forcePhrase, value.contains(where: { "()<>@,;:\\\".[]".contains($0) }) {
                return "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
            }
            return value
        }
        let encoded = Data(value.utf8).base64EncodedString()
        return "=?UTF-8?B?\(encoded)?="
    }

    /// RFC 2045 quoted-printable, with soft line breaks at 76 characters.
    static func quotedPrintable(_ text: String) -> String {
        var output = ""
        var lineLength = 0

        func appendToken(_ token: String) {
            // A token must not be split across a soft break, or it decodes wrong.
            if lineLength + token.count > 75 {
                output += "=\r\n"
                lineLength = 0
            }
            output += token
            lineLength += token.count
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let bytes = Array(Data(line.utf8))
            for (index, byte) in bytes.enumerated() {
                let isLast = index == bytes.count - 1
                switch byte {
                case 0x20, 0x09:
                    // Trailing whitespace is stripped in transit unless encoded.
                    appendToken(isLast ? String(format: "=%02X", byte) : String(UnicodeScalar(byte)))
                case 0x21...0x3C, 0x3E...0x7E:
                    appendToken(String(UnicodeScalar(byte)))
                default:
                    // Includes '=' (0x3D) and everything non-ASCII.
                    appendToken(String(format: "=%02X", byte))
                }
            }
            output += "\r\n"
            lineLength = 0
        }
        // split() leaves a trailing empty component for a trailing newline; the
        // loop above already terminated the previous line, so drop the extra.
        if output.hasSuffix("\r\n\r\n") {
            output.removeLast(2)
        }
        return output
    }

    static func rfc5322Date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        return formatter.string(from: date)
    }
}
