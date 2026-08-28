import Foundation
import Testing
@testable import SMTPKit

@Suite("SMTP message")
struct SMTPMessageTests {
    private let sent = Date(timeIntervalSince1970: 1_700_000_000)

    private func render(_ message: SMTPMessage) -> String {
        message.rendered(date: sent, messageID: "fixed@example.com")
    }

    @Test("The headers receivers check are all present")
    func requiredHeaders() {
        let rendered = render(
            SMTPMessage(
                from: "alerts@example.com",
                fromName: "YealinkMonitor",
                to: ["ops@example.com"],
                subject: "3 phones offline",
                body: "Body."
            )
        )

        // Missing Date or Message-ID is a reliable way to be filed as spam,
        // which for an alerting system is the same as not sending at all.
        #expect(rendered.contains("Message-ID: <fixed@example.com>"))
        #expect(rendered.contains("From: YealinkMonitor <alerts@example.com>"))
        #expect(rendered.contains("To: <ops@example.com>"))
        #expect(rendered.contains("Subject: 3 phones offline"))
        #expect(rendered.contains("MIME-Version: 1.0"))
        #expect(rendered.contains("Content-Type: text/plain; charset=utf-8"))
        // Tells mailing lists and autoresponders not to reply to this.
        #expect(rendered.contains("Auto-Submitted: auto-generated"))
        #expect(rendered.range(of: #"Date: \w{3}, \d{1,2} \w{3} \d{4}"#, options: .regularExpression) != nil)
    }

    @Test("Headers and body are separated by exactly one blank line")
    func headerBodySeparator() {
        let rendered = render(
            SMTPMessage(from: "a@example.com", to: ["b@example.com"], subject: "s", body: "Body.")
        )
        let parts = rendered.components(separatedBy: "\r\n\r\n")
        #expect(parts.count == 2)
        #expect(parts[1] == "Body.\r\n")
    }

    @Test("Every recipient appears in the To header")
    func multipleRecipients() {
        let rendered = render(
            SMTPMessage(
                from: "a@example.com",
                to: ["b@example.com", "c@example.com"],
                subject: "s",
                body: "x"
            )
        )
        #expect(rendered.contains("To: <b@example.com>, <c@example.com>"))
    }

    @Test("A non-ASCII subject is RFC 2047 encoded rather than sent raw")
    func encodedSubject() {
        let rendered = render(
            SMTPMessage(
                from: "a@example.com",
                to: ["b@example.com"],
                subject: "Ōtāhuhu phone offline",
                body: "x"
            )
        )
        // Raw UTF-8 in a header is not legal and arrives as mojibake.
        #expect(rendered.contains("Subject: =?UTF-8?B?"))
        #expect(!rendered.contains("Subject: Ōtāhuhu"))
    }

    @Test("An ASCII display name with specials is quoted, not encoded")
    func quotedDisplayName() {
        #expect(SMTPMessage.address("a@example.com", name: "Ops, Night") == "\"Ops, Night\" <a@example.com>")
        #expect(SMTPMessage.address("a@example.com", name: "Ops") == "Ops <a@example.com>")
        #expect(SMTPMessage.address("a@example.com", name: nil) == "<a@example.com>")
    }

    @Test("Quoted-printable escapes what it must and leaves the rest readable")
    func quotedPrintableBasics() {
        #expect(SMTPMessage.quotedPrintable("plain text") == "plain text\r\n")
        // '=' is the escape character and so must itself be escaped.
        #expect(SMTPMessage.quotedPrintable("a=b") == "a=3Db\r\n")
        // Trailing whitespace is stripped in transit unless encoded.
        #expect(SMTPMessage.quotedPrintable("trailing ") == "trailing=20\r\n")
        #expect(SMTPMessage.quotedPrintable("Ōtāhuhu").hasPrefix("=C5=8Ct=C4=81huhu"))
    }

    @Test("Long lines get soft breaks inside the 76-character limit")
    func quotedPrintableSoftBreaks() {
        let encoded = SMTPMessage.quotedPrintable(String(repeating: "a", count: 200))
        for line in encoded.components(separatedBy: "\r\n") {
            #expect(line.count <= 76)
        }
        // A soft break is a trailing '=' and must not appear in the decoded text.
        #expect(encoded.contains("=\r\n"))
        #expect(encoded.replacingOccurrences(of: "=\r\n", with: "")
            .trimmingCharacters(in: .newlines) == String(repeating: "a", count: 200))
    }

    @Test("Line structure survives encoding")
    func quotedPrintableLines() {
        #expect(SMTPMessage.quotedPrintable("one\ntwo") == "one\r\ntwo\r\n")
        #expect(SMTPMessage.quotedPrintable("one\n\ntwo") == "one\r\n\r\ntwo\r\n")
        // Bare LF in the source becomes a proper CRLF on the wire.
        #expect(!SMTPMessage.quotedPrintable("one\ntwo").contains("\n\n"))
    }

    @Test("The Message-ID domain comes from the sender")
    func messageIDDomain() {
        #expect(SMTPMessage(from: "a@example.com", to: [], subject: "", body: "").messageIDDomain == "example.com")
        #expect(SMTPMessage(from: "broken", to: [], subject: "", body: "").messageIDDomain == "localhost")
    }
}
