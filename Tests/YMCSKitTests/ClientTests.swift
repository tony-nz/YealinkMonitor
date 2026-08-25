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
