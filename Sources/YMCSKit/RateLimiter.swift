import Foundation

/// Paces outbound requests.
///
/// YMCS allows 50 requests/second, but that budget is *per enterprise* and is
/// shared with every other integration using the same credentials. This app is
/// a passive monitor, so it deliberately claims a small slice of it.
///
/// Implemented as a shaper rather than a gate: `reserve()` always succeeds and
/// returns how long the caller should wait before sending, so no request is
/// ever dropped and callers never spin.
public actor RateLimiter {
    private let emissionInterval: Duration
    private let tolerance: Duration
    private let clock = ContinuousClock()

    /// Theoretical arrival time of the next conforming request.
    private var tat: ContinuousClock.Instant
    /// Set when the server returns 429; no request is released before this.
    private var cooldownUntil: ContinuousClock.Instant?

    /// - Parameters:
    ///   - requestsPerSecond: sustained rate. Default 5/s -- a tenth of the
    ///     documented enterprise limit, leaving headroom for other consumers.
    ///   - burst: how many requests may go out back-to-back after an idle
    ///     period. Sized to cover a few pages of `listDevices`.
    public init(requestsPerSecond: Double = 5, burst: Int = 10) {
        precondition(requestsPerSecond > 0, "rate must be positive")
        self.emissionInterval = .seconds(1 / requestsPerSecond)
        // One slot is always available from `emissionInterval` itself, so the
        // tolerance only has to cover the remaining `burst - 1`.
        self.tolerance = .seconds(Double(max(burst, 1) - 1) / requestsPerSecond)
        self.tat = clock.now
    }

    /// Claims a slot and reports how long to wait before using it.
    public func reserve() -> Duration {
        let now = clock.now
        var delay = max(.zero, (tat - tolerance) - now)
        if let cooldownUntil, cooldownUntil > now {
            delay = max(delay, cooldownUntil - now)
        }
        tat = max(tat, now) + emissionInterval
        return delay
    }

    /// Records a 429. The API contract mandates exponential backoff with a
    /// minimum delay of 30 seconds, so nothing shorter is ever honoured.
    public func noteRateLimited(retryAfter: Duration) {
        let backoff = max(retryAfter, .seconds(30))
        let candidate = clock.now + backoff
        if let existing = cooldownUntil, existing > candidate { return }
        cooldownUntil = candidate
    }

    /// Clears the 429 cooldown, e.g. when the user explicitly asks to retry.
    public func clearCooldown() {
        cooldownUntil = nil
    }

    /// How long callers are currently being held back, if at all.
    public var remainingCooldown: Duration? {
        guard let cooldownUntil else { return nil }
        let now = clock.now
        return cooldownUntil > now ? cooldownUntil - now : nil
    }
}
