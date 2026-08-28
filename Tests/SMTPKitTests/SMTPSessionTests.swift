import Foundation
import Testing
@testable import SMTPKit

@Suite("SMTP session")
struct SMTPSessionTests {
    private let message = SMTPMessage(
        from: "alerts@example.com",
        fromName: "YealinkMonitor",
        to: ["ops@example.com"],
        subject: "3 phones offline",
        body: "Reception, Workshop and Spare stopped responding."
    )

    private func session(_ transport: ScriptedTransport) -> SMTPSession {
        SMTPSession(
            transport: transport,
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            makeMessageID: { domain in "fixed-id@\(domain)" }
        )
    }

    private var server: SMTPServer {
        SMTPServer(
            host: "smtp.example.com",
            encryption: .startTLS,
            username: "alerts@example.com",
            clientName: "yealinkmonitor.local"
        )
    }

    /// The reply script for a server that offers STARTTLS and AUTH.
    private var happyPath: [String] {
        [
            "220 smtp.example.com ESMTP",
            "250-smtp.example.com",
            "250-STARTTLS",
            "250 AUTH PLAIN LOGIN",
            "220 Ready to start TLS",
            "250-smtp.example.com",
            "250 AUTH PLAIN LOGIN",
            "235 Authentication succeeded",
            "250 OK",
            "250 Accepted",
            "354 End data with <CR><LF>.<CR><LF>",
            "250 OK id=1",
            "221 Bye",
        ]
    }

    @Test("The conversation follows RFC 5321 in order")
    func fullConversation() async throws {
        let transport = ScriptedTransport(lines: happyPath)
        try await session(transport).send(message, server: server, password: "hunter2")

        let written = await transport.written
        #expect(written[0] == "EHLO yealinkmonitor.local")
        #expect(written[1] == "STARTTLS")
        #expect(written[2] == "EHLO yealinkmonitor.local")
        #expect(written[3].hasPrefix("AUTH PLAIN "))
        #expect(written[4] == "MAIL FROM:<alerts@example.com>")
        #expect(written[5] == "RCPT TO:<ops@example.com>")
        #expect(written[6] == "DATA")
        #expect(written.last == "QUIT")
        #expect(await transport.isClosed)
    }

    @Test("EHLO is repeated after the TLS handshake")
    func ehloIsRepeatedAfterTLS() async throws {
        let transport = ScriptedTransport(lines: happyPath)
        try await session(transport).send(message, server: server, password: "hunter2")

        #expect(await transport.didStartTLS)
        // Capabilities advertised before the handshake cannot be trusted, and
        // AUTH is commonly only offered once the channel is encrypted.
        let afterTLS = await transport.tlsStartedAfterLines
        let written = await transport.written
        #expect(written[afterTLS] == "EHLO yealinkmonitor.local")
    }

    @Test("The password is never sent when STARTTLS is unavailable")
    func refusesToSendPasswordInTheClear() async throws {
        let transport = ScriptedTransport(lines: [
            "220 smtp.example.com ESMTP",
            "250-smtp.example.com",
            "250 AUTH PLAIN LOGIN",
        ])

        await #expect(throws: SMTPError.self) {
            try await session(transport).send(message, server: server, password: "hunter2")
        }
        #expect(await !transport.transcript.contains("hunter2"))
        #expect(await !transport.transcript.contains("AUTH"))
    }

    @Test("Authenticating over an unencrypted connection is refused off the loopback")
    func refusesPlaintextAuth() async throws {
        var plain = server
        plain.encryption = .none
        let transport = ScriptedTransport(lines: [
            "220 smtp.example.com ESMTP",
            "250-smtp.example.com",
            "250 AUTH PLAIN LOGIN",
        ])

        await #expect(throws: SMTPError.self) {
            try await session(transport).send(message, server: plain, password: "hunter2")
        }
        #expect(await !transport.transcript.contains("hunter2"))
    }

    @Test("A local relay may authenticate without encryption")
    func allowsPlaintextAuthOnLoopback() async throws {
        var local = server
        local.host = "localhost"
        local.encryption = .none
        let transport = ScriptedTransport(lines: [
            "220 localhost ESMTP",
            "250-localhost",
            "250 AUTH PLAIN",
            "235 OK",
            "250 OK",
            "250 Accepted",
            "354 Go ahead",
            "250 OK",
            "221 Bye",
        ])

        try await session(transport).send(message, server: local, password: "hunter2")
        #expect(await transport.written.contains { $0.hasPrefix("AUTH PLAIN ") })
    }

    @Test("AUTH LOGIN is used when PLAIN is not offered")
    func authLoginFallback() async throws {
        let transport = ScriptedTransport(lines: [
            "220 smtp.example.com ESMTP",
            "250-smtp.example.com",
            "250-STARTTLS",
            "250 AUTH LOGIN",
            "220 Ready to start TLS",
            "250-smtp.example.com",
            "250 AUTH LOGIN",
            "334 VXNlcm5hbWU6",
            "334 UGFzc3dvcmQ6",
            "235 OK",
            "250 OK",
            "250 Accepted",
            "354 Go ahead",
            "250 OK",
            "221 Bye",
        ])

        try await session(transport).send(message, server: server, password: "hunter2")

        let written = await transport.written
        #expect(written[3] == "AUTH LOGIN")
        #expect(written[4] == Data("alerts@example.com".utf8).base64EncodedString())
        #expect(written[5] == Data("hunter2".utf8).base64EncodedString())
    }

    @Test("A rejection names the step that failed without echoing the password")
    func rejectionIsReportedSafely() async throws {
        let transport = ScriptedTransport(lines: [
            "220 smtp.example.com ESMTP",
            "250-smtp.example.com",
            "250-STARTTLS",
            "250 AUTH PLAIN",
            "220 Ready to start TLS",
            "250-smtp.example.com",
            "250 AUTH PLAIN",
            "535 5.7.8 Authentication credentials invalid",
        ])

        do {
            try await session(transport).send(message, server: server, password: "hunter2")
            Issue.record("expected a rejection")
        } catch let error as SMTPError {
            guard case .rejected(let command, let reply) = error else {
                Issue.record("expected .rejected, got \(error)")
                return
            }
            #expect(command == "authentication")
            #expect(reply.code == 535)
            // The command that failed carried the credential; the error must not.
            let described = error.errorDescription ?? ""
            #expect(!described.contains("hunter2"))
        }
    }

    @Test("A rejected recipient is reported as such")
    func rejectedRecipient() async throws {
        // Through authentication, then accept MAIL FROM and refuse the recipient.
        let transport = ScriptedTransport(lines: happyPath.prefix(8) + [
            "250 OK",
            "550 5.1.1 No such user",
        ])

        do {
            try await session(transport).send(message, server: server, password: "hunter2")
            Issue.record("expected a rejection")
        } catch let error as SMTPError {
            guard case .rejected(let command, _) = error else {
                Issue.record("expected .rejected, got \(error)")
                return
            }
            #expect(command == "RCPT TO")
        }
    }

    @Test("Every recipient gets its own RCPT TO")
    func multipleRecipients() async throws {
        var many = message
        many.to = ["ops@example.com", "oncall@example.com"]
        let transport = ScriptedTransport(lines: [
            "220 smtp.example.com ESMTP",
            "250-smtp.example.com",
            "250-STARTTLS",
            "250 AUTH PLAIN",
            "220 Ready",
            "250-smtp.example.com",
            "250 AUTH PLAIN",
            "235 OK",
            "250 OK",
            "250 Accepted",
            "250 Accepted",
            "354 Go ahead",
            "250 OK",
            "221 Bye",
        ])

        try await session(transport).send(many, server: server, password: "hunter2")

        let written = await transport.written
        #expect(written.filter { $0.hasPrefix("RCPT TO:") } == [
            "RCPT TO:<ops@example.com>",
            "RCPT TO:<oncall@example.com>",
        ])
    }

    @Test("Sending with no recipient fails before connecting")
    func noRecipients() async throws {
        var empty = message
        empty.to = []
        let transport = ScriptedTransport(lines: [])

        await #expect(throws: SMTPError.self) {
            try await session(transport).send(empty, server: server, password: "")
        }
        #expect(await !transport.didConnect)
    }

    @Test("A line starting with a dot is stuffed so it cannot end the message")
    func dotStuffing() {
        #expect(SMTPSession.dotStuffed("first\r\n.hidden\r\nlast") == "first\r\n..hidden\r\nlast")
        #expect(SMTPSession.dotStuffed(".leading") == "..leading")
        #expect(SMTPSession.dotStuffed("no dots here") == "no dots here")
    }

    @Test("The body is terminated with the end-of-data sequence")
    func bodyIsTerminated() async throws {
        let transport = ScriptedTransport(lines: happyPath)
        try await session(transport).send(message, server: server, password: "hunter2")

        #expect(await transport.raw.contains("\r\n.\r\n"))
    }
}
