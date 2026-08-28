import Foundation

/// A line-oriented byte pipe to an SMTP server.
///
/// Split out from the conversation so the protocol logic -- which is where the
/// bugs live -- can be tested against a scripted server with no sockets.
public protocol SMTPTransport: Sendable {
    func connect() async throws
    /// One CRLF-terminated line, with the terminator stripped.
    func receiveLine() async throws -> String
    func send(_ data: Data) async throws
    /// Upgrades the *existing* connection to TLS, after a 220 to STARTTLS.
    func startTLS() async throws
    func close() async
}

/// CFStream-backed transport.
///
/// Deliberately not `NWConnection`: Network.framework cannot upgrade a live
/// connection to TLS, and STARTTLS on port 587 is the only submission method
/// several major providers (Microsoft 365 among them) offer. CFStream can be
/// switched to TLS in place, which is the whole reason it is used here.
public final class StreamSMTPTransport: SMTPTransport, @unchecked Sendable {
    private let host: String
    private let port: Int
    private let usesTLSImmediately: Bool
    /// Serial: every access to the streams and the buffer happens here, which is
    /// what makes the `@unchecked Sendable` above true.
    private let queue = DispatchQueue(label: "nz.co.myers.YealinkMonitor.smtp")

    private var input: InputStream?
    private var output: OutputStream?
    private var buffer = Data()

    public init(host: String, port: Int, usesTLSImmediately: Bool) {
        self.host = host
        self.port = port
        self.usesTLSImmediately = usesTLSImmediately
    }

    public func connect() async throws {
        try await onQueue { [self] in
            var input: InputStream?
            var output: OutputStream?
            Stream.getStreamsToHost(withName: host, port: port, inputStream: &input, outputStream: &output)
            guard let input, let output else {
                throw SMTPError.connectionFailed(
                    NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNREFUSED))
                )
            }
            if usesTLSImmediately {
                Self.enableTLS(on: input, and: output, host: host)
            }
            input.open()
            output.open()
            if let error = input.streamError ?? output.streamError {
                throw SMTPError.connectionFailed(error)
            }
            self.input = input
            self.output = output
        }
    }

    public func receiveLine() async throws -> String {
        try await onQueue { [self] in
            while true {
                if let line = takeBufferedLine() { return line }
                guard let input else { throw SMTPError.connectionClosed }

                var chunk = [UInt8](repeating: 0, count: 4096)
                // Blocking. `close()` from another thread unblocks it, which is
                // how the client's timeout is enforced.
                let read = input.read(&chunk, maxLength: chunk.count)
                if read < 0 {
                    throw input.streamError.map { SMTPError.connectionFailed($0) } ?? .connectionClosed
                }
                if read == 0 { throw SMTPError.connectionClosed }
                buffer.append(contentsOf: chunk[0..<read])
            }
        }
    }

    public func send(_ data: Data) async throws {
        try await onQueue { [self] in
            guard let output else { throw SMTPError.connectionClosed }
            var remaining = data
            while !remaining.isEmpty {
                let written = remaining.withUnsafeBytes { raw -> Int in
                    guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                    return output.write(base, maxLength: remaining.count)
                }
                if written <= 0 {
                    throw output.streamError.map { SMTPError.connectionFailed($0) } ?? .connectionClosed
                }
                remaining.removeFirst(written)
            }
        }
    }

    public func startTLS() async throws {
        try await onQueue { [self] in
            guard let input, let output else { throw SMTPError.connectionClosed }
            // Anything already buffered was sent before the handshake and must
            // not be trusted afterwards -- that is the STARTTLS injection bug.
            buffer.removeAll()
            Self.enableTLS(on: input, and: output, host: host)
        }
    }

    public func close() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                input?.close()
                output?.close()
                input = nil
                output = nil
                buffer.removeAll()
                continuation.resume()
            }
        }
    }

    /// Closes without waiting for the queue, so it can interrupt a blocked read.
    /// The streams are closed from this thread on purpose.
    public func interrupt() {
        input?.close()
        output?.close()
    }

    // MARK: - Plumbing

    private func takeBufferedLine() -> String? {
        guard let range = buffer.range(of: Data("\r\n".utf8)) else { return nil }
        let line = buffer[..<range.lowerBound]
        buffer.removeSubrange(..<range.upperBound)
        return String(decoding: line, as: UTF8.self)
    }

    private static func enableTLS(on input: InputStream, and output: OutputStream, host: String) {
        let settings: [String: Any] = [
            kCFStreamSSLPeerName as String: host,
        ]
        input.setProperty(settings, forKey: .init(kCFStreamPropertySSLSettings as String))
        output.setProperty(settings, forKey: .init(kCFStreamPropertySSLSettings as String))
        input.setProperty(StreamSocketSecurityLevel.negotiatedSSL, forKey: .socketSecurityLevelKey)
        output.setProperty(StreamSocketSecurityLevel.negotiatedSSL, forKey: .socketSecurityLevelKey)
    }

    private func onQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try work() })
            }
        }
    }
}
