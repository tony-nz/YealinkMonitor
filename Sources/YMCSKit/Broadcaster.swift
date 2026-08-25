import Foundation

/// Fans one source of values out to many independent consumers.
///
/// A bare `AsyncStream` supports a single iterator, and cancelling that
/// iterator terminates the stream for everyone who comes later -- a quiet
/// failure that looks like "events just stopped arriving". This app has several
/// legitimate listeners (menu bar, window, notifications, history), so each gets
/// its own stream.
///
/// Subscription is synchronous, so a consumer created before a value is sent
/// cannot miss it.
final class Broadcaster<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]
    private let bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy

    init(bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy = .unbounded) {
        self.bufferingPolicy = bufferingPolicy
    }

    func subscribe() -> AsyncStream<Element> {
        AsyncStream(Element.self, bufferingPolicy: bufferingPolicy) { continuation in
            let id = UUID()
            lock.withLock { continuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                lock.withLock { _ = self.continuations.removeValue(forKey: id) }
            }
        }
    }

    func yield(_ value: Element) {
        let targets = lock.withLock { Array(continuations.values) }
        for continuation in targets {
            continuation.yield(value)
        }
    }

    func finish() {
        let targets = lock.withLock {
            defer { continuations.removeAll() }
            return Array(continuations.values)
        }
        for continuation in targets {
            continuation.finish()
        }
    }

    var subscriberCount: Int {
        lock.withLock { continuations.count }
    }
}

extension NSLock {
    fileprivate func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
