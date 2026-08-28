import Foundation
@testable import SMTPKit

/// A scripted stand-in for a submission server.
///
/// Replies are queued as raw lines in the order the server would send them, and
/// everything the client writes is recorded, so a test can assert on the exact
/// conversation rather than on whether a socket happened to work.
actor ScriptedTransport: SMTPTransport {
    private var pendingLines: [String]
    /// Exactly what the client wrote, terminators and all.
    private(set) var raw: [String] = []
    private(set) var didStartTLS = false
    private(set) var tlsStartedAfterLines = 0
    private(set) var isClosed = false
    private(set) var didConnect = false

    init(lines: [String]) {
        self.pendingLines = lines
    }

    func connect() async throws {
        didConnect = true
    }

    func receiveLine() async throws -> String {
        guard !pendingLines.isEmpty else { throw SMTPError.connectionClosed }
        return pendingLines.removeFirst()
    }

    func send(_ data: Data) async throws {
        raw.append(String(decoding: data, as: UTF8.self))
    }

    /// The same writes with their line terminators removed, which is the form
    /// assertions want. Note that CRLF is a single Swift `Character`, so this
    /// cannot be done by dropping two characters.
    var written: [String] {
        raw.map { $0.trimmingCharacters(in: .newlines) }
    }

    func startTLS() async throws {
        didStartTLS = true
        tlsStartedAfterLines = raw.count
    }

    func close() async {
        isClosed = true
    }

    /// Everything the client wrote, for asserting that a secret did not escape.
    var transcript: String { raw.joined() }
}
