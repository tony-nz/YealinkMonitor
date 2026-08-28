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

    @Test("Only active alarms reach the snapshot")
    func activeAlarmsOnly() async throws {
        let server = FakeServer(
            devices: [.stub("1", .online, name: "Reception")],
            alarms: [
                .stub("a1", mac: "001565bbb1a9", event: "Offline", status: .active),
                .stub("a2", mac: "001565bbb1a9", event: "Handset lost", status: .solved),
                .stub("a3", mac: "001565bbb1a9", event: "Noisy line", status: .ignored),
            ]
        )
        let monitor = makeMonitor(server, clock: MutableDate(.init(timeIntervalSince1970: 0)))
        await monitor.poll()

        let snapshot = await monitor.current
        // `listAlarms` has no status filter, so solved and ignored alarms come
        // back with the active ones and must be dropped here.
        #expect(snapshot.alarms.map(\.id) == ["a1"])
        #expect(snapshot.alarmTotal == 3)
    }

    @Test("Alarms are matched to devices across MAC formatting")
    func alarmsMatchOnNormalisedMAC() async throws {
        let device = Device(id: "1", mac: "001565bbb1a9", deviceStatus: .online)
        let server = FakeServer(
            devices: [device],
            // listDevices returns bare MACs, listAlarms punctuated ones.
            alarms: [.stub("a1", mac: "00:15:65:BB:B1:A9")]
        )
        let monitor = makeMonitor(server, clock: MutableDate(.init(timeIntervalSince1970: 0)))
        await monitor.poll()

        let snapshot = await monitor.current
        #expect(snapshot.alarms(for: device).map(\.id) == ["a1"])
        #expect(snapshot.alarmedDeviceCount == 1)
    }

    @Test("A failing alarm list does not fail the poll")
    func alarmFailureIsNotFatal() async throws {
        let server = FakeServer(devices: [.stub("1", .online), .stub("2", .offline)])
        server.failAlarms(with: 500)
        let monitor = makeMonitor(server, clock: MutableDate(.init(timeIntervalSince1970: 0)))
        await monitor.poll()

        let snapshot = await monitor.current
        // Alarms are decoration; the device list is the product.
        #expect(snapshot.devices.count == 2)
        #expect(snapshot.failure == nil)
        #expect(snapshot.alarms.isEmpty)
    }

    @Test("Alarms are not refetched on every full refresh")
    func alarmsRespectTheirOwnInterval() async throws {
        let server = FakeServer(
            devices: [.stub("1", .online)],
            alarms: [.stub("a1", mac: "001565bbb1a9")]
        )
        let clock = MutableDate(.init(timeIntervalSince1970: 0))
        let monitor = makeMonitor(server, clock: clock) { configuration in
            configuration.alarmRefresh = .seconds(300)
        }

        await monitor.poll()
        clock.value.addTimeInterval(60)
        await monitor.refreshNow()
        #expect(server.count("/v2/dm/listAlarms") == 1)

        clock.value.addTimeInterval(300)
        await monitor.refreshNow()
        #expect(server.count("/v2/dm/listAlarms") == 2)
    }

    @Test("A cleared alarm disappears from the snapshot on the next alarm refresh")
    func clearedAlarmsAreDropped() async throws {
        let server = FakeServer(
            devices: [.stub("1", .online)],
            alarms: [.stub("a1", mac: "001565bbb1a9")]
        )
        let clock = MutableDate(.init(timeIntervalSince1970: 0))
        let monitor = makeMonitor(server, clock: clock)

        await monitor.poll()
        #expect(await monitor.current.alarms.count == 1)

        server.alarms = []
        clock.value.addTimeInterval(600)
        await monitor.refreshNow()
        #expect(await monitor.current.alarms.isEmpty)
    }

    // MARK: - Reboot

    @Test("A reboot sends the documented body and reports what YMCS accepted")
    func rebootSendsDocumentedBody() async throws {
        let server = FakeServer(devices: [.stub("1", .online), .stub("2", .online)])
        let monitor = makeMonitor(server, clock: MutableDate(.init(timeIntervalSince1970: 0)))
        await monitor.poll()

        let result = try await monitor.reboot(deviceIDs: ["1", "2"])

        #expect(result.total == 2)
        #expect(result.successCount == 2)
        #expect(result.didFullySucceed)
        let body = try #require(server.rebootRequests.first)
        #expect(body["deviceIds"] as? [String] == ["1", "2"])
        // The model lookup says these are phones; the device list never does.
        #expect(body["deviceType"] as? Int == 1)
    }

    @Test("A partial failure is reported rather than treated as success")
    func rebootPartialFailure() async throws {
        let server = FakeServer(devices: [.stub("1", .online), .stub("2", .online)])
        server.rejectReboots(of: ["2"])
        let monitor = makeMonitor(server, clock: MutableDate(.init(timeIntervalSince1970: 0)))
        await monitor.poll()

        let result = try await monitor.reboot(deviceIDs: ["1", "2"])

        // The endpoint answers 200 for this, so nothing throws and the counts
        // are the only signal there is.
        #expect(result.failureCount == 1)
        #expect(result.didFullySucceed == false)
        #expect(result.errors?.compactMap(\.field) == ["2"])
    }

    @Test("A rebooted phone dropping is attributed to the reboot, not reported as an outage")
    func rebootSuppressesTheDrop() async throws {
        let server = FakeServer(devices: [.stub("1", .online, name: "Reception")])
        let clock = MutableDate(.init(timeIntervalSince1970: 0))
        let monitor = makeMonitor(server, clock: clock) { $0.confirmations = 1 }
        await monitor.poll()

        _ = try await monitor.reboot(deviceIDs: ["1"], settlingWindow: .seconds(600))

        let changes = monitor.changes
        server.setStatus(.offline, forDeviceID: "1")
        clock.value.addTimeInterval(60)
        await monitor.poll()

        let change = try #require(await firstChange(changes))
        #expect(change.to == .offline)
        #expect(change.cause == .reboot)
        // The alerting layer keys off this: a drop we caused is not an outage.
        #expect(change.isRegression == false)
    }

    @Test("A phone that comes back inside the window is not announced as a recovery")
    func rebootSuppressesTheRecovery() async throws {
        let server = FakeServer(devices: [.stub("1", .online)])
        let clock = MutableDate(.init(timeIntervalSince1970: 0))
        let monitor = makeMonitor(server, clock: clock) { $0.confirmations = 1 }
        await monitor.poll()
        _ = try await monitor.reboot(deviceIDs: ["1"], settlingWindow: .seconds(600))

        server.setStatus(.offline, forDeviceID: "1")
        clock.value.addTimeInterval(60)
        await monitor.poll()

        let changes = monitor.changes
        server.setStatus(.online, forDeviceID: "1")
        clock.value.addTimeInterval(60)
        await monitor.poll()

        let change = try #require(await firstChange(changes))
        #expect(change.to == .online)
        #expect(change.cause == .reboot)
    }

    @Test("A phone that never comes back is reported once the window closes")
    func rebootFailureSurfacesAtExpiry() async throws {
        let server = FakeServer(devices: [.stub("1", .online, name: "Reception")])
        let clock = MutableDate(.init(timeIntervalSince1970: 0))
        let monitor = makeMonitor(server, clock: clock) { $0.confirmations = 1 }
        await monitor.poll()
        _ = try await monitor.reboot(deviceIDs: ["1"], settlingWindow: .seconds(600))

        server.setStatus(.offline, forDeviceID: "1")
        clock.value.addTimeInterval(60)
        await monitor.poll()

        let changes = monitor.changes
        // The detector settled on offline while suppressed, so without the
        // expiry check this phone would stay silently dead forever.
        clock.value.addTimeInterval(600)
        await monitor.poll()

        let change = try #require(await firstChange(changes))
        #expect(change.from == .online)
        #expect(change.to == .offline)
        #expect(change.cause == .observed)
        #expect(change.isRegression)
    }

    @Test("A phone YMCS refused to reboot is not given a settling window")
    func rejectedRebootIsNotSuppressed() async throws {
        let server = FakeServer(devices: [.stub("1", .online), .stub("2", .online)])
        server.rejectReboots(of: ["2"])
        let clock = MutableDate(.init(timeIntervalSince1970: 0))
        let monitor = makeMonitor(server, clock: clock) { $0.confirmations = 1 }
        await monitor.poll()

        _ = try await monitor.reboot(deviceIDs: ["1", "2"])

        // Nothing was done to device 2, so whatever happens to it next is real.
        #expect(await monitor.settlingDeviceIDs == ["1"])
    }

    @Test("A settling window keeps the poller taking full listings")
    func settlingForcesFullRefresh() async throws {
        let server = FakeServer(devices: [.stub("1", .online)])
        let clock = MutableDate(.init(timeIntervalSince1970: 0))
        let monitor = makeMonitor(server, clock: clock)
        await monitor.poll()
        _ = try await monitor.reboot(deviceIDs: ["1"], settlingWindow: .seconds(600))

        clock.value.addTimeInterval(60)
        await monitor.poll()

        // The cheap offline count cannot say *which* phone came back.
        #expect(server.count("/v2/dm/listDevices") == 2)
        #expect(server.count("/v2/dm/statistics/deviceCount") == 0)
    }

    @Test("Reboot ids are deduplicated before they reach the server")
    func rebootDeduplicates() async throws {
        let server = FakeServer(devices: [.stub("1", .online)])
        let monitor = makeMonitor(server, clock: MutableDate(.init(timeIntervalSince1970: 0)))
        await monitor.poll()

        let result = try await monitor.reboot(deviceIDs: ["1", "1", "1"])

        // Otherwise the server's own totals count the same phone three times.
        #expect(result.total == 1)
        #expect(server.rebootRequests.first?["deviceIds"] as? [String] == ["1"])
    }

    @Test("A room device is rebooted as a room device")
    func rebootUsesTheResolvedDeviceType() async throws {
        var room = Device.stub("9", .online, name: "Boardroom")
        room = Device(
            id: room.id, mac: room.mac, sn: room.sn, name: room.name,
            modelId: "m9", siteId: room.siteId,
            programVersion: room.programVersion, deviceStatus: room.deviceStatus
        )
        let server = FakeServer(devices: [.stub("1", .online), room])
        let monitor = makeMonitor(server, clock: MutableDate(.init(timeIntervalSince1970: 0)))
        await monitor.poll()

        _ = try await monitor.reboot(deviceIDs: ["1", "9"])

        // One call per type: the endpoint takes a single deviceType for the
        // whole batch, and sending the wrong one reboots nothing.
        let byType = Dictionary(
            uniqueKeysWithValues: server.rebootRequests.map {
                ($0["deviceType"] as? Int ?? -1, $0["deviceIds"] as? [String] ?? [])
            }
        )
        #expect(byType[1] == ["1"])
        #expect(byType[3] == ["9"])
    }

    // MARK: - Accessories

    @Test("Accessories are grouped under the device they are attached to")
    func accessoriesAreGrouped() async throws {
        let server = FakeServer(
            devices: [.stub("1", .online), .stub("2", .online)],
            accessories: [
                .stub("p1", parent: "1", model: "EXP50"),
                .stub("p2", parent: "1", model: "WH66"),
                .stub("p3", parent: "2", model: "CP700"),
            ]
        )
        let monitor = makeMonitor(server, clock: MutableDate(.init(timeIntervalSince1970: 0)))
        await monitor.poll()

        let snapshot = await monitor.current
        #expect(snapshot.accessories["1"]?.count == 2)
        #expect(snapshot.accessories["2"]?.map(\.displayName) == ["CP700"])
    }

    @Test("A phone with a dead accessory is flagged even though the phone is online")
    func accessoryProblemsAreVisible() async throws {
        let server = FakeServer(
            devices: [.stub("1", .online, name: "Reception")],
            accessories: [.stub("p1", parent: "1", status: .offline)]
        )
        let monitor = makeMonitor(server, clock: MutableDate(.init(timeIntervalSince1970: 0)))
        await monitor.poll()

        let snapshot = await monitor.current
        // The failure the device status alone hides completely.
        #expect(snapshot.problems.isEmpty)
        #expect(snapshot.devicesWithAccessoryProblems.map(\.id) == ["1"])
    }

    @Test("An accessory that has never reported is not treated as a fault")
    func neverReportedAccessoryIsNotAProblem() async throws {
        let server = FakeServer(
            devices: [.stub("1", .online)],
            accessories: [.stub("p1", parent: "1", status: .notReported)]
        )
        let monitor = makeMonitor(server, clock: MutableDate(.init(timeIntervalSince1970: 0)))
        await monitor.poll()

        // Registered in YMCS but never plugged in is not a fault to alert on.
        #expect(await monitor.current.devicesWithAccessoryProblems.isEmpty)
    }

    @Test("Accessories are not refetched on every full refresh")
    func accessoriesRespectTheirOwnInterval() async throws {
        let server = FakeServer(
            devices: [.stub("1", .online)],
            accessories: [.stub("p1", parent: "1")]
        )
        let clock = MutableDate(.init(timeIntervalSince1970: 0))
        let monitor = makeMonitor(server, clock: clock) { $0.accessoryRefresh = .seconds(900) }

        await monitor.poll()
        clock.value.addTimeInterval(600)
        await monitor.refreshNow()
        #expect(server.count("/v2/dm/device/listParts") == 1)

        clock.value.addTimeInterval(900)
        await monitor.refreshNow()
        #expect(server.count("/v2/dm/device/listParts") == 2)
    }

    // MARK: - Firmware

    @Test("Firmware versions compare numerically, not as strings")
    func firmwareOrdering() {
        // The case a string comparison gets backwards.
        #expect(Device.isFirmware("70.9.0.1", olderThan: "70.83.0.1"))
        #expect(!Device.isFirmware("70.83.0.68", olderThan: "70.83.0.68"))
        #expect(Device.isFirmware("70.83", olderThan: "70.83.0.1"))
        #expect(!Device.isFirmware("71.0.0.0", olderThan: "70.99.9.9"))
    }

    @Test("The fleet reference is the commonest version, not the highest")
    func fleetFirmwareIsModal() async throws {
        let server = FakeServer(devices: [
            .stubFirmware("1", "70.83.0.68"),
            .stubFirmware("2", "70.83.0.68"),
            .stubFirmware("3", "70.83.0.68"),
            // One phone on a newer build must not make the other three look
            // out of date.
            .stubFirmware("4", "70.90.0.1"),
            .stubFirmware("5", "70.10.0.1"),
        ])
        let monitor = makeMonitor(server, clock: MutableDate(.init(timeIntervalSince1970: 0)))
        await monitor.poll()

        let snapshot = await monitor.current
        #expect(snapshot.fleetFirmware["m1"] == "70.83.0.68")
        #expect(snapshot.isBehindFleetFirmware(snapshot.devices.first { $0.id == "5" }!))
        #expect(!snapshot.isBehindFleetFirmware(snapshot.devices.first { $0.id == "4" }!))
        #expect(!snapshot.isBehindFleetFirmware(snapshot.devices.first { $0.id == "1" }!))
    }

    @Test("A device with no firmware or model is never reported as behind")
    func firmwareUnknownIsNotBehind() async throws {
        let server = FakeServer(devices: [.stub("1", .online), .stubFirmware("2", "70.83.0.68")])
        let monitor = makeMonitor(server, clock: MutableDate(.init(timeIntervalSince1970: 0)))
        await monitor.poll()

        let snapshot = await monitor.current
        #expect(!snapshot.isBehindFleetFirmware(snapshot.devices.first { $0.id == "1" }!))
    }

    // MARK: - Device detail sweep

    @Test("The detail sweep fills in what the device list leaves out")
    func detailSweepFillsIPs() async throws {
        let server = FakeServer(devices: [.stub("1", .online), .stub("2", .online)])
        let monitor = makeMonitor(server, clock: MutableDate(.init(timeIntervalSince1970: 0)))
        await monitor.poll()

        let snapshot = await monitor.current
        // listDevices returns no IP at all; only the per-device endpoint does.
        #expect(snapshot.lanIP(for: snapshot.devices[0]) == "10.42.0.1")
        #expect(snapshot.detail(for: snapshot.devices[1])?.sn == "SN2")
    }

    @Test("The sweep costs one request per phone and then stops")
    func detailSweepCost() async throws {
        let server = FakeServer(devices: (1...5).map { .stub("\($0)", .online) })
        let clock = MutableDate(.init(timeIntervalSince1970: 0))
        let monitor = makeMonitor(server, clock: clock) { $0.detailRefresh = .seconds(1800) }

        await monitor.poll()
        #expect(server.count("/v2/dm/devices/1") == 1)

        // Well inside the interval: the expensive sweep must not repeat.
        clock.value.addTimeInterval(600)
        await monitor.refreshNow()
        #expect(server.count("/v2/dm/devices/1") == 1)

        clock.value.addTimeInterval(1800)
        await monitor.refreshNow()
        #expect(server.count("/v2/dm/devices/1") == 2)
    }

    @Test("A phone that has left the fleet loses its cached detail")
    func detailSweepDropsRemovedDevices() async throws {
        let server = FakeServer(devices: [.stub("1", .online), .stub("2", .online)])
        let clock = MutableDate(.init(timeIntervalSince1970: 0))
        let monitor = makeMonitor(server, clock: clock)
        await monitor.poll()
        #expect(await monitor.current.details.count == 2)

        server.devices = [.stub("1", .online)]
        clock.value.addTimeInterval(1800)
        await monitor.refreshNow()

        let snapshot = await monitor.current
        // Otherwise a decommissioned phone's IP lingers in the export forever.
        #expect(snapshot.details.keys.sorted() == ["1"])
    }

    @Test("A detail request that fails leaves the previous value in place")
    func detailSweepKeepsLastGood() async throws {
        let server = FakeServer(devices: [.stub("1", .online)])
        let clock = MutableDate(.init(timeIntervalSince1970: 0))
        let monitor = makeMonitor(server, clock: clock)
        await monitor.poll()
        #expect(await monitor.current.details["1"]?.lanIp == "10.42.0.1")

        // Fail every request in the next sweep, detail included.
        server.fail(times: 20, with: HTTPResponse(status: 500, body: Data(#"{"message":"boom"}"#.utf8)))
        clock.value.addTimeInterval(1800)
        await monitor.refreshNow()

        // Blanking the IP column on a transient error would be worse than
        // showing one that is half an hour old.
        #expect(await monitor.current.details["1"]?.lanIp == "10.42.0.1")
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
