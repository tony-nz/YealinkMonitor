import Foundation
import Testing
@testable import YMCSKit

@Suite("Client")
struct ClientTests {
    private func makeClient(_ transport: StubTransport) -> YMCSClient {
        YMCSClient(
            transport: transport,
            credentialsProvider: StaticCredentialsProvider(.test),
            // Wide open, so tests never actually sleep.
            rateLimiter: RateLimiter(requestsPerSecond: 10_000, burst: 1000)
        )
    }

    @Test("The token request matches the documented contract")
    func tokenRequestShape() async throws {
        let transport = StubTransport()
        await transport.enqueue(.fixture("token"), .fixture("listDevices"))
        _ = try await makeClient(transport).listDevices()

        let token = try #require(await transport.recorded.first)
        #expect(token.method == "POST")
        #expect(token.path == "/v2/token")
        // Basic base64(clientId:clientSecret)
        #expect(token.header("Authorization") == "Basic \(Data("id:secret".utf8).base64EncodedString())")
        #expect(String(data: token.body ?? Data(), encoding: .utf8) == "grant_type=client_credentials")
        #expect(token.url.host() == "au-api.ymcs.yealink.com")
    }

    @Test("Every request carries a timestamp and a nonce of at most 32 characters")
    func signingHeaders() async throws {
        let transport = StubTransport()
        await transport.enqueue(.fixture("token"), .fixture("listDevices"))
        _ = try await makeClient(transport).listDevices()

        var seenNonces = Set<String>()
        for request in await transport.recorded {
            let timestamp = try #require(request.header("timestamp"))
            let milliseconds = try #require(Int64(timestamp))
            // Sanity-check the unit: seconds-since-epoch would be ~1000x small.
            #expect(milliseconds > 1_600_000_000_000)

            let nonce = try #require(request.header("nonce"))
            #expect(nonce.count <= 32)
            seenNonces.insert(nonce)
        }
        // Nonces must not repeat across requests.
        #expect(seenNonces.count == (await transport.requestCount))
    }

    @Test("Business requests use Bearer auth and reuse the cached token")
    func tokenIsCached() async throws {
        let transport = StubTransport()
        await transport.enqueue(
            .fixture("token"),
            .fixture("listDevices"),
            .json(#"{"total":7}"#)
        )
        let client = makeClient(transport)
        _ = try await client.listDevices()
        _ = try await client.deviceCount(status: .offline)

        let tokenRequests = await transport.requests(matching: "/v2/token")
        #expect(tokenRequests.count == 1, "the second call must not re-authenticate")

        let business = await transport.recorded.filter { $0.path != "/v2/token" }
        #expect(business.count == 2)
        for request in business {
            #expect(request.header("Authorization") == "Bearer tok_abc123")
        }
    }

    @Test("A 401 on a business request triggers exactly one re-authentication")
    func retriesOnceAfter401() async throws {
        let transport = StubTransport()
        await transport.enqueue(
            .fixture("token"),
            .json(#"{"message":"token expired"}"#, status: 401),
            .json(#"{"access_token":"tok_second","expires_in":7200}"#),
            .fixture("listDevices")
        )
        let page = try await makeClient(transport).listDevices()
        #expect(page.items.count == 3)

        let recorded = await transport.recorded
        #expect(recorded.count == 4)
        #expect(recorded[3].header("Authorization") == "Bearer tok_second")
    }

    @Test("A second 401 is surfaced rather than retried forever")
    func doesNotRetryTwice() async throws {
        let transport = StubTransport()
        await transport.enqueue(
            .fixture("token"),
            .fixture("error401", status: 401),
            .json(#"{"access_token":"tok_second","expires_in":7200}"#),
            .fixture("error401", status: 401)
        )
        await #expect(throws: YMCSError.self) {
            _ = try await makeClient(transport).listDevices()
        }
        #expect(await transport.requestCount == 4)
    }

    @Test("A 429 is reported with a backoff of at least the mandated 30 seconds")
    func rateLimitedIsHonoured() async throws {
        let transport = StubTransport()
        await transport.enqueue(
            .fixture("token"),
            HTTPResponse(status: 429, headers: ["Retry-After": "5"], body: Data())
        )
        let limiter = RateLimiter(requestsPerSecond: 10_000, burst: 1000)
        let client = YMCSClient(
            transport: transport,
            credentialsProvider: StaticCredentialsProvider(.test),
            rateLimiter: limiter
        )

        do {
            _ = try await client.listDevices()
            Issue.record("expected a rate-limit error")
        } catch let error as YMCSError {
            guard case .rateLimited(let retryAfter) = error else {
                Issue.record("expected .rateLimited, got \(error)")
                return
            }
            // The server asked for 5s; the API contract mandates a 30s floor.
            #expect(retryAfter >= .seconds(30))
            #expect(error.isRetryable)
        }

        let cooldown = try #require(await limiter.remainingCooldown)
        #expect(cooldown > .seconds(29))
    }

    @Test("Authentication failure is not retryable and carries the server's message")
    func authFailureIsTerminal() async throws {
        let transport = StubTransport()
        await transport.enqueue(.fixture("error401", status: 401))
        do {
            _ = try await makeClient(transport).listDevices()
            Issue.record("expected an authentication error")
        } catch let error as YMCSError {
            guard case .authenticationFailed(let body) = error else {
                Issue.record("expected .authenticationFailed, got \(error)")
                return
            }
            #expect(body?.message == "Invalid client credentials")
            #expect(!error.isRetryable)
        }
    }

    @Test("allDevices pages at 100 and counts only on the first page")
    func pagination() async throws {
        func page(_ count: Int, total: Int, skip: Int) -> HTTPResponse {
            let rows = (0..<count).map { index in
                #"{"id":"d\#(skip + index)","mac":"001565bbb1a9","deviceStatus":"online"}"#
            }
            return .json(#"{"skip":\#(skip),"limit":100,"total":\#(total),"data":[\#(rows.joined(separator: ","))]}"#)
        }

        let transport = StubTransport()
        await transport.enqueue(
            .fixture("token"),
            page(100, total: 230, skip: 0),
            page(100, total: 230, skip: 100),
            page(30, total: 230, skip: 200)
        )

        let devices = try await makeClient(transport).allDevices()
        #expect(devices.count == 230)
        #expect(devices.first?.id == "d0")
        #expect(devices.last?.id == "d229")

        let listCalls = await transport.requests(matching: "/v2/dm/listDevices")
        #expect(listCalls.count == 3)
        #expect(listCalls[0].jsonBody?["autoCount"] as? Bool == true)
        // autoCount forces the server to count the whole result set; asking on
        // every page would triple that work for no benefit.
        #expect(listCalls[1].jsonBody?["autoCount"] as? Bool == false)
        #expect(listCalls[1].jsonBody?["skip"] as? Int == 100)
        #expect(listCalls[2].jsonBody?["skip"] as? Int == 200)
    }

    @Test("A short final page ends pagination without an extra request")
    func paginationStopsOnShortPage() async throws {
        let transport = StubTransport()
        await transport.enqueue(.fixture("token"), .fixture("listDevices"))
        let devices = try await makeClient(transport).allDevices()
        #expect(devices.count == 3)
        #expect(await transport.requests(matching: "/v2/dm/listDevices").count == 1)
    }

    @Test("An empty filter is omitted from the request body entirely")
    func emptyFilterIsOmitted() async throws {
        let transport = StubTransport()
        await transport.enqueue(.fixture("token"), .fixture("listDevices"), .fixture("listDevices"))
        let client = makeClient(transport)
        _ = try await client.listDevices(filter: DeviceFilter())
        _ = try await client.listDevices(filter: DeviceFilter(status: .offline, siteId: "s1"))

        let calls = await transport.requests(matching: "/v2/dm/listDevices")
        #expect(calls[0].jsonBody?["filter"] == nil)
        let filter = try #require(calls[1].jsonBody?["filter"] as? [String: Any])
        #expect(filter["deviceStatus"] as? Int == 0)
        #expect(filter["siteId"] as? String == "s1")
    }

    @Test("deviceCount sends the documented query parameters")
    func deviceCountQuery() async throws {
        let transport = StubTransport()
        await transport.enqueue(.fixture("token"), .json(#"{"total":12}"#))
        let count = try await makeClient(transport).deviceCount(status: .offline, type: .phone)
        #expect(count == 12)

        let request = try #require(await transport.requests(matching: "/v2/dm/statistics/deviceCount").first)
        #expect(request.method == "GET")
        let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.contains(URLQueryItem(name: "deviceStatus", value: "0")))
        #expect(query.contains(URLQueryItem(name: "deviceType", value: "1")))
    }

    @Test("The models endpoint is accepted in both documented shapes")
    func modelsAcceptsBothShapes() async throws {
        let bare = StubTransport()
        await bare.enqueue(.fixture("token"), .json(#"[{"id":"m1","name":"SIP-T54S"}]"#))
        #expect(try await makeClient(bare).models(deviceType: .phone).first?.name == "SIP-T54S")

        let wrapped = StubTransport()
        await wrapped.enqueue(.fixture("token"), .json(#"{"data":[{"id":"m1","name":"SIP-T54S"}]}"#))
        #expect(try await makeClient(wrapped).models(deviceType: .phone).first?.name == "SIP-T54S")
    }

    @Test("Missing credentials fail before any network request is attempted")
    func missingCredentials() async throws {
        let transport = StubTransport()
        let client = YMCSClient(
            transport: transport,
            credentialsProvider: StaticCredentialsProvider(environment: [:])
        )
        await #expect(throws: YMCSError.self) { try await client.verifyConnection() }
        #expect(await transport.requestCount == 0)
    }

    @Test("A reboot larger than one page is chunked and the results are summed")
    func rebootChunks() async throws {
        let server = FakeServer(devices: [])
        let client = YMCSClient(
            transport: server.makeTransport(),
            credentialsProvider: StaticCredentialsProvider(.test),
            rateLimiter: RateLimiter(requestsPerSecond: 10_000, burst: 1000)
        )

        let ids = (1...250).map(String.init)
        let result = try await client.rebootDevices(ids: ids)

        #expect(server.rebootRequests.count == 3)
        #expect(server.rebootRequests.map { ($0["deviceIds"] as? [String] ?? []).count } == [100, 100, 50])
        // One number for the user, not three.
        #expect(result.total == 250)
        #expect(result.successCount == 250)
    }

    @Test("An empty reboot makes no request at all")
    func rebootOfNothing() async throws {
        let server = FakeServer(devices: [])
        let client = YMCSClient(
            transport: server.makeTransport(),
            credentialsProvider: StaticCredentialsProvider(.test),
            rateLimiter: RateLimiter(requestsPerSecond: 10_000, burst: 1000)
        )

        let result = try await client.rebootDevices(ids: [])

        #expect(result.total == 0)
        #expect(server.totalRequests == 0)
    }

    // MARK: - Diagnostics

    private func diagnosticClient(_ server: FakeServer) -> YMCSClient {
        YMCSClient(
            transport: server.makeTransport(),
            credentialsProvider: StaticCredentialsProvider(.test),
            rateLimiter: RateLimiter(requestsPerSecond: 10_000, burst: 1000)
        )
    }

    @Test("Ping sends the documented body")
    func pingBody() async throws {
        let server = FakeServer()
        let ticket = try await diagnosticClient(server).startPing(deviceID: "d1", host: "10.0.0.1", times: 4)

        #expect(ticket.diagnosisId == "diag-1")
        let request = try #require(server.diagnosticRequests.first)
        #expect(request.path == "/v2/dm/devices/d1/ping")
        #expect(request.body["host"] as? String == "10.0.0.1")
        #expect(request.body["times"] as? Int == 4)
    }

    @Test("Probe counts outside the documented range are clamped, not sent")
    func probeCountClamped() async throws {
        let server = FakeServer()
        let client = diagnosticClient(server)
        _ = try await client.startPing(deviceID: "d1", host: "h", times: 99)
        _ = try await client.startTraceroute(deviceID: "d1", host: "h", times: 0)

        // Sending 99 would just cost a round trip to be told 1-30.
        #expect(server.diagnosticRequests[0].body["times"] as? Int == 30)
        #expect(server.diagnosticRequests[1].body["times"] as? Int == 1)
    }

    @Test("Packet capture clamps its duration and only sends a filter when asked to")
    func packetCaptureBody() async throws {
        let server = FakeServer()
        let client = diagnosticClient(server)
        _ = try await client.startPacketCapture(
            deviceID: "d1", networkInterface: "wlan0", type: .rtp, filter: "ignored", duration: 10
        )
        _ = try await client.startPacketCapture(
            deviceID: "d1", type: .custom, filter: "port 5060", duration: 99_999
        )

        #expect(server.diagnosticRequests[0].body["duration"] as? Int == 180)
        #expect(server.diagnosticRequests[0].body["networkInterface"] as? String == "wlan0")
        // The API only reads `filter` for the custom type; sending it otherwise
        // invites confusion about why it had no effect.
        #expect(server.diagnosticRequests[0].body["filter"] == nil)
        #expect(server.diagnosticRequests[1].body["duration"] as? Int == 3600)
        #expect(server.diagnosticRequests[1].body["filter"] as? String == "port 5060")
    }

    @Test("A diagnostic is polled until it finishes and yields its download link")
    func awaitDiagnosticPolls() async throws {
        let server = FakeServer()
        server.reportInProgress(times: 2)

        let status = try await diagnosticClient(server)
            .awaitDiagnostic(id: "diag-1", pollInterval: .milliseconds(1))

        #expect(status.status == .success)
        #expect(status.downloadURL?.absoluteString == "https://example.com/log.txt")
        #expect(server.count("/v2/dm/diagnosis/diag-1/status") == 3)
    }

    @Test("A failed diagnostic finishes without a download link")
    func failedDiagnostic() async throws {
        let server = FakeServer()
        server.finishDiagnostics(as: "failure")

        let status = try await diagnosticClient(server)
            .awaitDiagnostic(id: "diag-1", pollInterval: .milliseconds(1))

        #expect(status.status == .failure)
        #expect(status.downloadURL == nil)
    }

    @Test("A diagnostic that never finishes times out rather than waiting forever")
    func diagnosticTimeout() async throws {
        let server = FakeServer()
        // A phone that drops mid-diagnostic never reports anything again.
        server.reportInProgress(times: .max)

        await #expect(throws: YMCSError.self) {
            try await diagnosticClient(server).awaitDiagnostic(
                id: "diag-1",
                pollInterval: .milliseconds(1),
                timeout: .milliseconds(10)
            )
        }
    }

    @Test("Accessories for many devices come back as a bare array")
    func batchAccessories() async throws {
        let server = FakeServer(accessories: [
            .stub("p1", parent: "d1"),
            .stub("p2", parent: "d2", status: .offline),
        ])

        let parts = try await diagnosticClient(server).accessories(forDeviceIDs: ["d1", "d2"])

        #expect(parts.count == 2)
        // The batch endpoint quotes connStatus; the per-device one does not.
        #expect(parts.first { $0.id == "p2" }?.isProblem == true)
    }

    // MARK: - Call quality and logs

    @Test("A call query sends its filter in milliseconds")
    func callFilter() async throws {
        let server = FakeServer()
        let since = Date(timeIntervalSince1970: 1_700_000_000)
        let until = Date(timeIntervalSince1970: 1_700_086_400)

        let page = try await diagnosticClient(server).listCalls(
            mac: "001565bbb1a9", since: since, until: until
        )

        #expect(page.items.first?.quality == .good)
        let filter = try #require(server.bodies(for: "/v2/dm/listQoes").first?["filter"] as? [String: Any])
        #expect(filter["mac"] as? String == "001565bbb1a9")
        // YMCS takes epoch milliseconds; seconds would silently query 1970.
        #expect(filter["startTime"] as? Int64 == 1_700_000_000_000)
        #expect(filter["endTime"] as? Int64 == 1_700_086_400_000)
    }

    @Test("Call duration comes from the timestamps, not the mislabelled field")
    func callDurationUnits() async throws {
        let server = FakeServer()
        let page = try await diagnosticClient(server).listCalls()
        let call = try #require(page.items.first)

        // The document calls `duration` milliseconds. The server sends 41 for a
        // 41-second call, so trusting the document renders every call as 0s.
        #expect(call.duration == 41)
        #expect(call.durationSeconds == 41)
    }

    @Test("An uppercase quality still decodes")
    func callQualityCase() async throws {
        let server = FakeServer()
        let page = try await diagnosticClient(server).listCalls()

        // The document's example says "Good"; the server sends "GOOD".
        #expect(page.items.first?.quality == .good)
    }

    @Test("A call query with no filter omits the key entirely")
    func emptyCallFilter() async throws {
        let server = FakeServer()
        _ = try await diagnosticClient(server).listCalls()

        #expect(server.bodies(for: "/v2/dm/listQoes").first?["filter"] == nil)
    }

    @Test("Call quality statistics send a time range only as a complete pair")
    func statisticsTimeRange() async throws {
        let server = FakeServer()
        let client = diagnosticClient(server)
        // The API ignores a start without an end, so sending one alone would
        // silently return all-time figures under a date heading.
        _ = try await client.callQualityStatistics(since: Date(timeIntervalSince1970: 1))
        _ = try await client.callQualityStatistics(
            since: Date(timeIntervalSince1970: 1),
            until: Date(timeIntervalSince1970: 2)
        )

        let bodies = server.bodies(for: "/v2/dm/statistics/qoe")
        #expect(bodies[0]["startTime"] == nil)
        #expect(bodies[1]["startTime"] as? Int64 == 1000)
        #expect(bodies[1]["endTime"] as? Int64 == 2000)
    }

    @Test("Quality statistics decode the documented fields")
    func statisticsDecode() async throws {
        let server = FakeServer()
        let stats = try await diagnosticClient(server).callQualityStatistics()

        #expect(stats.total == 100)
        #expect(stats.badTotal == 7)
        #expect(stats.badPercentage == 7.0)
    }

    @Test("An operation log decodes despite the document's misspelled field")
    func operationLogDecoding() async throws {
        let server = FakeServer()
        let page = try await diagnosticClient(server).listOperationLogs()

        let log = try #require(page.items.first)
        // The field table says operationType, the worked example says
        // operationTypetype. Both are accepted.
        #expect(log.operationType == "i18n.yiot.backend.operation.device.management.restart")
        #expect(log.operator == "tony")
        #expect(OperationLog.readable(log.operationType) == "Management Restart")
    }

    @Test("Region selection changes the host that is contacted")
    func regionRouting() async throws {
        let transport = StubTransport()
        await transport.enqueue(.fixture("token"), .fixture("listDevices"))
        let client = YMCSClient(
            transport: transport,
            credentialsProvider: StaticCredentialsProvider(
                Credentials(clientID: "id", clientSecret: "secret", region: .eu)
            ),
            rateLimiter: RateLimiter(requestsPerSecond: 10_000, burst: 1000)
        )
        try await client.verifyConnection()
        for request in await transport.recorded {
            #expect(request.url.host() == "eu-api.ymcs.yealink.com")
        }
    }
}
