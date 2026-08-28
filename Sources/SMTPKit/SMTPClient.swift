import Foundation

/// One SMTP submission, start to finish, over a transport that is already
/// pointed at the right host.
///
/// Everything here is ordinary RFC 5321: greeting, EHLO, optional STARTTLS,
/// optional AUTH, envelope, DATA. It is written out longhand rather than pulled
/// in as a dependency because it is the only reason the app would need one.
public struct SMTPSession: Sendable {
    private let transport: any SMTPTransport
    private let now: @Sendable () -> Date
    private let makeMessageID: @Sendable (String) -> String

    public init(
        transport: any SMTPTransport,
        now: @escaping @Sendable () -> Date = { Date() },
        makeMessageID: @escaping @Sendable (String) -> String = { domain in
            "\(UUID().uuidString.lowercased())@\(domain)"
        }
    ) {
        self.transport = transport
        self.now = now
        self.makeMessageID = makeMessageID
    }

    public func send(
        _ message: SMTPMessage,
        server: SMTPServer,
        password: String
    ) async throws {
        guard !message.to.isEmpty else { throw SMTPError.noRecipients }

        try await transport.connect()
        try await expect(2, command: "connect")

        var capabilities = try await greet(server)

        if server.encryption == .startTLS {
            guard capabilities.contains(where: { $0.uppercased().hasPrefix("STARTTLS") }) else {
                throw SMTPError.encryptionUnavailable
            }
            try await write("STARTTLS")
            try await expect(2, command: "STARTTLS")
            try await transport.startTLS()
            // The capability list from before the handshake is not trustworthy,
            // and servers legitimately advertise different things afterwards
            // (AUTH usually appears only once the channel is encrypted).
            capabilities = try await greet(server)
        }

        if !server.username.isEmpty {
            // Refusing beats quietly putting the password on the wire in the
            // clear. A relay on the loopback interface is the one case where
            // there is no wire to put it on.
            guard server.encryption != .none || Self.isLoopback(server.host) else {
                throw SMTPError.encryptionUnavailable
            }
            try await authenticate(server: server, password: password, capabilities: capabilities)
        }

        try await write("MAIL FROM:<\(message.from)>")
        try await expect(2, command: "MAIL FROM")

        for recipient in message.to {
            try await write("RCPT TO:<\(recipient)>")
            try await expect(2, command: "RCPT TO")
        }

        try await write("DATA")
        try await expect(3, command: "DATA")

        let rendered = message.rendered(
            date: now(),
            messageID: makeMessageID(message.messageIDDomain)
        )
        try await transport.send(Data(Self.dotStuffed(rendered).utf8))
        try await transport.send(Data("\r\n.\r\n".utf8))
        try await expect(2, command: "message body")

        // A server that dislikes QUIT has still accepted the mail, so this is
        // best effort and its reply is not checked.
        try? await write("QUIT")
        await transport.close()
    }

    // MARK: - Steps

    /// EHLO, falling back to HELO for the rare server that rejects it.
    private func greet(_ server: SMTPServer) async throws -> [String] {
        try await write("EHLO \(server.clientName)")
        let reply = try await readReply()
        if reply.code / 100 == 2 {
            return Array(reply.lines.dropFirst())
        }
        try await write("HELO \(server.clientName)")
        try await expect(2, command: "HELO")
        return []
    }

    private func authenticate(
        server: SMTPServer,
        password: String,
        capabilities: [String]
    ) async throws {
        let mechanisms = capabilities
            .first { $0.uppercased().hasPrefix("AUTH") }
            .map { $0.uppercased().split(whereSeparator: { $0 == " " || $0 == "=" }).map(String.init) } ?? []

        // PLAIN first: one round trip instead of three, and both are equally
        // safe now the channel is encrypted.
        if mechanisms.contains("PLAIN") || mechanisms.isEmpty {
            let token = Data("\0\(server.username)\0\(password)".utf8).base64EncodedString()
            // The command is not echoed into any error: it contains the password.
            try await write("AUTH PLAIN \(token)")
            try await expect(2, command: "authentication")
        } else if mechanisms.contains("LOGIN") {
            try await write("AUTH LOGIN")
            try await expect(3, command: "authentication")
            try await write(Data(server.username.utf8).base64EncodedString())
            try await expect(3, command: "authentication")
            try await write(Data(password.utf8).base64EncodedString())
            try await expect(2, command: "authentication")
        } else {
            throw SMTPError.noSupportedAuthMethod
        }
    }

    // MARK: - Wire

    private func write(_ line: String) async throws {
        try await transport.send(Data((line + "\r\n").utf8))
    }

    /// Reads a full reply, joining the `250-first` / `250 last` continuation
    /// form into one value.
    private func readReply() async throws -> SMTPReply {
        var lines: [String] = []
        var code: Int?

        while true {
            let raw = try await transport.receiveLine()
            guard raw.count >= 3, let parsed = Int(raw.prefix(3)) else {
                throw SMTPError.malformedReply(raw)
            }
            code = parsed
            let remainder = raw.dropFirst(3)
            lines.append(String(remainder.dropFirst()).trimmingCharacters(in: .whitespaces))
            if remainder.first != "-" { break }
        }
        return SMTPReply(code: code ?? 0, lines: lines)
    }

    @discardableResult
    private func expect(_ leadingDigit: Int, command: String) async throws -> SMTPReply {
        let reply = try await readReply()
        guard reply.code / 100 == leadingDigit else {
            throw SMTPError.rejected(command: command, reply: reply)
        }
        return reply
    }

    static func isLoopback(_ host: String) -> Bool {
        ["localhost", "127.0.0.1", "::1"].contains(host.lowercased())
    }

    /// A body line starting with "." would otherwise end the message early.
    static func dotStuffed(_ body: String) -> String {
        body
            .replacingOccurrences(of: "\r\n.", with: "\r\n..")
            .replacingOccurrences(
                of: "^\\.",
                with: "..",
                options: [.regularExpression]
            )
    }
}
