import Foundation

public struct StatusChange: Sendable, Hashable, Identifiable, Codable {
    /// Why the device changed status, as far as this app can tell.
    ///
    /// A phone this app rebooted drops and returns exactly like one that failed,
    /// so without this a deliberate restart would be alerted as an outage --
    /// including by email, at 3am, for a scheduled run.
    public enum Cause: String, Sendable, Hashable, Codable {
        /// Observed by polling. The device did this on its own.
        case observed
        /// Within the settling window after this app rebooted the device.
        case reboot
    }

    public let id: UUID
    public let device: Device
    /// Nil when the device was seen for the first time after priming.
    public let from: DeviceStatus?
    public let to: DeviceStatus
    public let at: Date
    public let cause: Cause

    public init(
        id: UUID = UUID(),
        device: Device,
        from: DeviceStatus?,
        to: DeviceStatus,
        at: Date,
        cause: Cause = .observed
    ) {
        self.id = id
        self.device = device
        self.from = from
        self.to = to
        self.at = at
        self.cause = cause
    }

    /// History written before `cause` existed decodes as `.observed` rather
    /// than failing -- a decode failure here empties the user's whole history.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        device = try container.decode(Device.self, forKey: .device)
        from = try container.decodeIfPresent(DeviceStatus.self, forKey: .from)
        to = try container.decode(DeviceStatus.self, forKey: .to)
        at = try container.decode(Date.self, forKey: .at)
        cause = try container.decodeIfPresent(Cause.self, forKey: .cause) ?? .observed
    }

    /// The same change, reattributed. Used when a reboot this app asked for
    /// turns out to explain a drop the detector just confirmed.
    public func attributed(to cause: Cause) -> StatusChange {
        StatusChange(id: id, device: device, from: from, to: to, at: at, cause: cause)
    }

    /// Worth interrupting someone for. A change this app caused is not.
    public var isRegression: Bool {
        cause == .observed && (to == .offline || to == .pending)
    }

    public var isRecovery: Bool {
        to == .online && from != nil && from != .online
    }
}

/// Turns a stream of polled device lists into confirmed status changes.
///
/// Raw poll results flap: a phone that misses a single check-in is reported
/// offline and is back a minute later. Alerting on that produces 3am
/// notifications nobody trusts. So a device must hold a new status across
/// several consecutive polls before the change is considered real.
///
/// The debounce is deliberately asymmetric. Going *offline* requires
/// `confirmations` consecutive polls, because a false alarm is expensive.
/// Coming back *online* is reported on the first poll that sees it, because a
/// false recovery is cheap and being told late that a phone is fixed is
/// annoying.
public struct TransitionDetector: Sendable {
    public let confirmations: Int

    private var confirmed: [String: DeviceStatus] = [:]
    private var candidates: [String: (status: DeviceStatus, count: Int)] = [:]
    private var isPrimed = false

    /// - Parameter confirmations: consecutive polls required to confirm a
    ///   regression. 1 disables debouncing.
    public init(confirmations: Int = 2) {
        self.confirmations = max(1, confirmations)
    }

    /// Devices whose status this detector currently considers settled.
    public var confirmedStatuses: [String: DeviceStatus] { confirmed }

    /// True while at least one device is part-way through confirmation.
    ///
    /// The Monitor uses this to keep taking full device listings until the
    /// debounce settles. Without it, a phone that drops and stays down is seen
    /// once, then hidden behind an unchanged offline count, and its second
    /// confirmation never arrives.
    public var hasPendingCandidates: Bool { !candidates.isEmpty }

    /// Whether the first poll has been absorbed. Until it has, no changes are
    /// emitted -- otherwise launching the app would alert on every phone that
    /// was already offline before it started.
    public var hasBaseline: Bool { isPrimed }

    public mutating func reset() {
        confirmed.removeAll()
        candidates.removeAll()
        isPrimed = false
    }

    @discardableResult
    public mutating func ingest(_ devices: [Device], at date: Date = Date()) -> [StatusChange] {
        guard isPrimed else {
            for device in devices { confirmed[device.id] = device.deviceStatus }
            candidates.removeAll()
            isPrimed = true
            return []
        }

        var changes: [StatusChange] = []
        var seen = Set<String>()

        for device in devices {
            seen.insert(device.id)
            let status = device.deviceStatus

            guard let current = confirmed[device.id] else {
                // A device added to YMCS while the app was running. Record it,
                // and report it if it arrives in a bad state.
                confirmed[device.id] = status
                candidates[device.id] = nil
                if status != .online {
                    changes.append(StatusChange(device: device, from: nil, to: status, at: date))
                }
                continue
            }

            if status == current {
                candidates[device.id] = nil
                continue
            }

            let required = status == .online ? 1 : confirmations
            let count = (candidates[device.id]?.status == status ? candidates[device.id]!.count : 0) + 1

            if count >= required {
                confirmed[device.id] = status
                candidates[device.id] = nil
                changes.append(StatusChange(device: device, from: current, to: status, at: date))
            } else {
                candidates[device.id] = (status, count)
            }
        }

        // Devices removed from YMCS simply drop out; that is an administrative
        // action, not an outage, so it is not reported as a change.
        for id in confirmed.keys where !seen.contains(id) {
            confirmed[id] = nil
            candidates[id] = nil
        }

        return changes
    }
}
