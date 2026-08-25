import Foundation
import Testing
@testable import YMCSKit

@Suite("Monitor")
struct MonitorTests {
    private func makeMonitor(
        _ server: FakeServer,
        clock: MutableDate,
        configure: (inout Monitor.Configuration) -> Void = { _ in }
    ) -> Monitor {
        var configuration = Monitor.Configuration()
        configuration.confirmations = 2
        configure(&configuration)
        let client = YMCSClient(
            transport: server.makeTransport(),
            credentialsProvider: StaticCredentialsProvider(.test),
            rateLimiter: RateLimiter(requestsPerSecond: 10_000, burst: 1000)
        )
        return Monitor(client: client, configuration: configuration, now: { clock.value })
    }

    /// Waits briefly for a change, rather than hanging if none arrives.
    ///
    /// Takes an already-subscribed stream: `monitor.changes` subscribes
    /// synchronously, so the caller must open it *before* the poll that is
    /// expected to produce the change.
    private func firstChange(
        _ stream: AsyncStream<StatusChange>,
        timeout: Duration = .milliseconds(500)
    ) async -> StatusChange? {
        await withTaskGroup(of: StatusChange?.self) { group in
            group.addTask { await stream.first { _ in true } }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    @Test("The first poll reads the full list and resolves model and site names")
    func firstPoll() async throws {
        let server = FakeServer(devices: [
            .stub("1", .online, name: "Reception"),
            .stub("2", .offline, name: "Workshop"),
            .stub("3", .pending, name: "Spare"),
        ])
        let monitor = makeMonitor(server, clock: MutableDate(.init(timeIntervalSince1970: 0)))
        await monitor.poll()

        let snapshot = await monitor.current
        #expect(snapshot.devices.count == 3)
        #expect(snapshot.onlineCount == 1)
        #expect(snapshot.offlineCount == 1)
        #expect(snapshot.pendingCount == 1)
        #expect(snapshot.failure == nil)
        #expect(snapshot.lastSuccess != nil)
        #expect(snapshot.modelNames["m1"] == "SIP-T54S")
        #expect(snapshot.siteNames["s1"] == "Head Office")
        // Offline sorts above pending; both above healthy devices.
        #expect(snapshot.problems.map(\.displayName) == ["Workshop", "Spare"])
    }

    @Test("A quiet interval costs one request, not a full listing")
    func heartbeatAvoidsFullListing() async throws {
        let server = FakeServer(devices: [.stub("1", .online), .stub("2", .offline)])
        let clock = MutableDate(.init(timeIntervalSince1970: 0))
        let monitor = makeMonitor(server, clock: clock)

        await monitor.poll()
        #expect(server.count("/v2/dm/listDevices") == 1)

        clock.value.addTimeInterval(60)
        await monitor.poll()
        clock.value.addTimeInterval(60)
        await monitor.poll()

        // Two further polls, two cheap count requests, and no re-listing.
        #expect(server.count("/v2/dm/statistics/deviceCount") == 2)
        #expect(server.count("/v2/dm/listDevices") == 1)
        // The heartbeat still counts as a successful read: the data on screen
        // is confirmed current, not merely old.
        #expect(await monitor.current.lastSuccess == clock.value)
    }

    @Test("A change in the offline count triggers a full refresh and a transition")
    func offlineCountTriggersRefresh() async throws {
        let server = FakeServer(devices: [.stub("1", .online, name: "Reception"), .stub("2", .online)])
        let clock = MutableDate(.init(timeIntervalSince1970: 0))
        let monitor = makeMonitor(server, clock: clock) { $0.confirmations = 1 }

        await monitor.poll()
        server.setStatus(.offline, forDeviceID: "1")

        clock.value.addTimeInterval(60)
        let changes = monitor.changes
        await monitor.poll()

        #expect(server.count("/v2/dm/listDevices") == 2)
        let observed = try #require(await firstChange(changes))
        #expect(observed.device.displayName == "Reception")
        #expect(observed.from == .online)
        #expect(observed.to == .offline)
        #expect(await monitor.current.offlineCount == 1)
    }

    @Test("Debouncing spans polls, so a single missed check-in stays silent")
    func debounceAcrossPolls() async throws {
        let server = FakeServer(devices: [.stub("1", .online)])
        let clock = MutableDate(.init(timeIntervalSince1970: 0))
        let monitor = makeMonitor(server, clock: clock) { $0.confirmations = 2 }

        await monitor.poll()
        server.setStatus(.offline, forDeviceID: "1")

        clock.value.addTimeInterval(60)
        let firstWindow = monitor.changes
        await monitor.poll()
        #expect(await firstChange(firstWindow) == nil, "one missed check-in must not alert")

        clock.value.addTimeInterval(60)
        let secondWindow = monitor.changes
        await monitor.poll()
        #expect(await firstChange(secondWindow) != nil, "a sustained outage must alert")
    }

    @Test("A swap that leaves the count unchanged is caught by the periodic full refresh")
    func periodicFullRefresh() async throws {
        let server = FakeServer(devices: [.stub("1", .online), .stub("2", .offline)])
        let clock = MutableDate(.init(timeIntervalSince1970: 0))
        let monitor = makeMonitor(server, clock: clock) { $0.fullRefresh = .seconds(600) }

        await monitor.poll()

        // One phone drops as another recovers: the offline count is identical,
        // so the heartbeat cannot see it.
        server.setStatus(.offline, forDeviceID: "1")
        server.setStatus(.online, forDeviceID: "2")

        clock.value.addTimeInterval(60)
        await monitor.poll()
        #expect(server.count("/v2/dm/listDevices") == 1, "the count is unchanged, so no re-listing")

        // The periodic full refresh bounds how long that can hide.
        clock.value.addTimeInterval(600)
        await monitor.poll()
        #expect(server.count("/v2/dm/listDevices") == 2)
        #expect(await monitor.current.problems.map(\.id) == ["1"])
    }

    @Test("refreshNow bypasses the heartbeat")
    func forcedRefresh() async throws {
        let server = FakeServer(devices: [.stub("1", .online)])
        let clock = MutableDate(.init(timeIntervalSince1970: 0))
        let monitor = makeMonitor(server, clock: clock)

        await monitor.poll()
        clock.value.addTimeInterval(5)
        await monitor.refreshNow()

        #expect(server.count("/v2/dm/listDevices") == 2)
        #expect(server.count("/v2/dm/statistics/deviceCount") == 0)
    }

    @Test("A failed poll keeps the last known devices on screen")
    func failureKeepsLastGoodData() async throws {
        let server = FakeServer(devices: [.stub("1", .online), .stub("2", .offline)])
        let clock = MutableDate(.init(timeIntervalSince1970: 0))
        let monitor = makeMonitor(server, clock: clock)

        await monitor.poll()
        let lastSuccess = await monitor.current.lastSuccess

        server.fail(with: HTTPResponse(status: 500, body: Data(#"{"message":"boom"}"#.utf8)))
        clock.value.addTimeInterval(60)
        await monitor.poll()

        let snapshot = await monitor.current
        // Showing "0 phones" on a transient server error would be far more
        // alarming than the truth.
        #expect(snapshot.devices.count == 2)
        #expect(snapshot.failure != nil)
        #expect(snapshot.failure?.needsAttention == false)
        // lastSuccess must not advance, so the UI can mark the data stale.
        #expect(snapshot.lastSuccess == lastSuccess)
        #expect(snapshot.lastAttempt == clock.value)
    }

    @Test("A credentials failure is flagged as needing the user's attention")
    func authFailureIsFlagged() async throws {
        let server = FakeServer(devices: [.stub("1", .online)])
        let clock = MutableDate(.init(timeIntervalSince1970: 0))
        let monitor = makeMonitor(server, clock: clock)

        // Twice: the client is entitled to re-authenticate once before
        // treating a 401 as a real credentials problem.
        server.fail(times: 2, with: HTTPResponse(status: 401, body: Data(#"{"message":"bad client"}"#.utf8)))
        await monitor.poll()

        let failure = try #require(await monitor.current.failure)
        #expect(failure.needsAttention)
        #expect(failure.message == "bad client")
    }

    @Test("Rate limiting is reported with its backoff, not as a credentials problem")
    func rateLimitFailure() async throws {
        let server = FakeServer(devices: [.stub("1", .online)])
        let clock = MutableDate(.init(timeIntervalSince1970: 0))
        let monitor = makeMonitor(server, clock: clock)

        server.fail(with: HTTPResponse(status: 429, headers: ["Retry-After": "60"], body: Data()))
        await monitor.poll()

        let failure = try #require(await monitor.current.failure)
        #expect(!failure.needsAttention)
        #expect(failure.retryAfter == .seconds(60))
    }

    @Test("Data older than the stale tolerance is not presented as current")
    func staleness() async throws {
        let server = FakeServer(devices: [.stub("1", .online)])
        let clock = MutableDate(.init(timeIntervalSince1970: 0))
        let monitor = makeMonitor(server, clock: clock) { $0.heartbeat = .seconds(60) }

        // Before any successful poll there is nothing to trust.
        #expect(await monitor.current.isStale(now: clock.value, tolerance: 180))

        await monitor.poll()
        let snapshot = await monitor.current
        #expect(!snapshot.isStale(now: clock.value, tolerance: 180))
        #expect(!snapshot.isStale(now: clock.value.addingTimeInterval(179), tolerance: 180))
        #expect(snapshot.isStale(now: clock.value.addingTimeInterval(181), tolerance: 180))
    }

    @Test("Reset clears cached state so new credentials start from scratch")
    func reset() async throws {
        let server = FakeServer(devices: [.stub("1", .online)])
        let clock = MutableDate(.init(timeIntervalSince1970: 0))
        let monitor = makeMonitor(server, clock: clock)

        await monitor.poll()
        await monitor.reset()

        let snapshot = await monitor.current
        #expect(snapshot.devices.isEmpty)
        #expect(snapshot.lastSuccess == nil)

        // The next poll re-lists rather than trusting a stale heartbeat.
        await monitor.poll()
        #expect(server.count("/v2/dm/listDevices") == 2)
    }
}

@Suite("Broadcast")
struct BroadcastTests {
    @Test("Several listeners each receive every change")
    func multipleSubscribers() async throws {
        let broadcaster = Broadcaster<Int>()
        let a = broadcaster.subscribe()
        let b = broadcaster.subscribe()
        #expect(broadcaster.subscriberCount == 2)

        broadcaster.yield(1)
        broadcaster.yield(2)
        broadcaster.finish()

        var fromA: [Int] = []
        for await value in a { fromA.append(value) }
        var fromB: [Int] = []
        for await value in b { fromB.append(value) }

        #expect(fromA == [1, 2])
        #expect(fromB == [1, 2])
    }

    @Test("One listener going away does not silence the others")
    func subscriberTerminationIsIsolated() async throws {
        let broadcaster = Broadcaster<Int>()
        let survivor = broadcaster.subscribe()

        // A short-lived consumer that cancels its iteration -- exactly what a
        // timed-out or torn-down view does.
        do {
            let transient = broadcaster.subscribe()
            let task = Task { await transient.first { _ in true } }
            task.cancel()
            _ = await task.value
        }

        broadcaster.yield(42)
        broadcaster.finish()

        var received: [Int] = []
        for await value in survivor { received.append(value) }
        #expect(received == [42])
    }
}
