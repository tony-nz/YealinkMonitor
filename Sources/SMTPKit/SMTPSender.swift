import Foundation

/// Sends one message over a real socket, with a bound on how long it may take.
///
/// The timeout matters more than it looks: this runs from a menu bar app's
/// alerting path, and a submission server that accepts the connection and then
/// says nothing would otherwise hang that path indefinitely.
public struct SMTPSender: Sendable {
    private let timeout: Duration

    public init(timeout: Duration = .seconds(30)) {
        self.timeout = timeout
    }

    public func send(
        _ message: SMTPMessage,
        server: SMTPServer,
        password: String
    ) async throws {
        guard server.isConfigured else { throw SMTPError.notConfigured }

        let transport = StreamSMTPTransport(
            host: server.host,
            port: server.port,
            usesTLSImmediately: server.encryption == .implicitTLS
        )
        let session = SMTPSession(transport: transport)

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await session.send(message, server: server, password: password)
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    // Closing the streams from here is what unblocks a read that
                    // is waiting on a server which has stopped talking.
                    transport.interrupt()
                    throw SMTPError.connectionClosed
                }
                try await group.next()
                group.cancelAll()
            }
        } catch {
            await transport.close()
            throw error
        }
    }
}
