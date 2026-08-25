import Foundation
import Testing
@testable import YMCSKit

@Suite("Rate limiting and tokens")
struct RateLimiterTests {
    @Test("A burst is released immediately, then requests are spaced out")
    func burstThenShaping() async {
        let limiter = RateLimiter(requestsPerSecond: 10, burst: 3)
        for _ in 0..<3 {
            #expect(await limiter.reserve() == .zero)
        }
        // The burst allowance is spent; the next slot has to wait.
        let delay = await limiter.reserve()
        #expect(delay > .zero)
        #expect(delay <= .milliseconds(100))
    }

    @Test("A 429 blocks everything for at least 30 seconds")
    func cooldownFloor() async {
        let limiter = RateLimiter(requestsPerSecond: 10_000, burst: 1000)
        #expect(await limiter.remainingCooldown == nil)

        // The server asked for 1s, but the API contract mandates 30s minimum.
        await limiter.noteRateLimited(retryAfter: .seconds(1))
        let delay = await limiter.reserve()
        #expect(delay > .seconds(29))

        await limiter.clearCooldown()
        #expect(await limiter.remainingCooldown == nil)
        #expect(await limiter.reserve() == .zero)
    }

    @Test("A longer cooldown is never shortened by a later, smaller one")
    func cooldownNeverShrinks() async {
        let limiter = RateLimiter(requestsPerSecond: 10_000, burst: 1000)
        await limiter.noteRateLimited(retryAfter: .seconds(300))
        await limiter.noteRateLimited(retryAfter: .seconds(30))
        let remaining = await limiter.remainingCooldown
        #expect((remaining ?? .zero) > .seconds(290))
    }

    @Test("Concurrent callers share one token request")
    func tokenSingleFlight() async throws {
        let transport = StubTransport()
        await transport.enqueue(.fixture("token"))
        let store = TokenStore(
            transport: transport,
            credentialsProvider: StaticCredentialsProvider(.test)
        )

        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<8 {
                group.addTask { try await store.accessToken() }
            }
            var results: [String] = []
            for try await token in group { results.append(token) }
            return results
        }

        #expect(tokens.allSatisfy { $0 == "tok_abc123" })
        // Eight concurrent callers, one trip to the token endpoint. YMCS issues
        // a single credential pair per enterprise, so stampeding it is a fast
        // route to a 429.
        #expect(await transport.requestCount == 1)
    }

    @Test("The token is refreshed before it expires, not after")
    func refreshesBeforeExpiry() async throws {
        let transport = StubTransport()
        await transport.enqueue(
            .json(#"{"access_token":"first","expires_in":100}"#),
            .json(#"{"access_token":"second","expires_in":100}"#)
        )
        let clock = MutableDate(Date(timeIntervalSince1970: 0))
        let store = TokenStore(
            transport: transport,
            credentialsProvider: StaticCredentialsProvider(.test),
            now: { clock.value }
        )

        #expect(try await store.accessToken() == "first")

        // 79% through the lifetime: still the original token.
        clock.value = Date(timeIntervalSince1970: 79)
        #expect(try await store.accessToken() == "first")
        #expect(await transport.requestCount == 1)

        // Past the 80% threshold, and still 20s before actual expiry, so a
        // request issued now cannot expire in flight.
        clock.value = Date(timeIntervalSince1970: 81)
        #expect(try await store.accessToken() == "second")
        #expect(await transport.requestCount == 2)
    }

    @Test("Invalidating forces a fresh token")
    func invalidate() async throws {
        let transport = StubTransport()
        await transport.enqueue(
            .json(#"{"access_token":"first","expires_in":7200}"#),
            .json(#"{"access_token":"second","expires_in":7200}"#)
        )
        let store = TokenStore(
            transport: transport,
            credentialsProvider: StaticCredentialsProvider(.test)
        )
        #expect(try await store.accessToken() == "first")
        await store.invalidate()
        #expect(try await store.accessToken() == "second")
    }
}

/// A trivially mutable clock for tests.
final class MutableDate: @unchecked Sendable {
    var value: Date
    init(_ value: Date) { self.value = value }
}
