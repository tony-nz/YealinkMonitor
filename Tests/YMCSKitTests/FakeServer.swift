import Foundation
@testable import YMCSKit

/// A minimal in-memory stand-in for YMCS: enough of `/v2/token`,
/// `listDevices`, `deviceCount`, `models` and `listSites` to drive the Monitor
/// through realistic scenarios.
final class FakeServer: @unchecked Sendable {
    private let lock = NSLock()
    private var _devices: [Device]
    private var _counts: [String: Int] = [:]
    private var _failWith: HTTPResponse?
    private var _failRemaining = 0

    init(devices: [Device] = []) {
        self._devices = devices
    }

    var devices: [Device] {
        get { lock.withLock { _devices } }
        set { lock.withLock { _devices = newValue } }
    }

    /// Number of times each path has been requested.
    func count(_ path: String) -> Int {
        lock.withLock { _counts[path] ?? 0 } 
    }

    var totalRequests: Int {
        lock.withLock { _counts.values.reduce(0, +) }
    }

    /// Makes the next `times` non-token requests fail. Use more than one when
    /// the client is expected to retry, e.g. after a 401.
    func fail(times: Int = 1, with response: HTTPResponse) {
        lock.withLock {
            _failWith = response
            _failRemaining = times
        }
    }

    /// Replaces the status of one device, as if it had dropped or recovered.
    func setStatus(_ status: DeviceStatus, forDeviceID id: String) {
        lock.withLock {
            guard let index = _devices.firstIndex(where: { $0.id == id }) else { return }
            let old = _devices[index]
            _devices[index] = Device(
                id: old.id, mac: old.mac, sn: old.sn, name: old.name,
                modelId: old.modelId, siteId: old.siteId,
                programVersion: old.programVersion, deviceStatus: status
            )
        }
    }

    func makeTransport() -> StubTransport {
        StubTransport(handler: { [weak self] request in
            self?.respond(to: request)
        })
    }

    private func respond(to request: StubTransport.Recorded) -> HTTPResponse {
        let path = request.url.path()
        lock.withLock { _counts[path, default: 0] += 1 }

        if path == "/v2/token" {
            return .json(#"{"access_token":"tok","token_type":"bearer","expires_in":7200}"#)
        }
        let queued: HTTPResponse? = lock.withLock {
            guard _failRemaining > 0, let response = _failWith else { return nil }
            _failRemaining -= 1
            return response
        }
        if let queued { return queued }

        let snapshot = devices
        switch path {
        case "/v2/dm/statistics/deviceCount":
            let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let wanted = query.first { $0.name == "deviceStatus" }?.value.flatMap(Int.init)
            let total = wanted == nil
                ? snapshot.count
                : snapshot.count { $0.deviceStatus.filterValue == wanted }
            return .json(#"{"total":\#(total)}"#)

        case "/v2/dm/listDevices":
            let body = request.jsonBody ?? [:]
            let skip = body["skip"] as? Int ?? 0
            let limit = body["limit"] as? Int ?? 100
            let slice = Array(snapshot.dropFirst(skip).prefix(limit))
            let rows = (try? JSONEncoder().encode(slice)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            return .json(#"{"skip":\#(skip),"limit":\#(limit),"total":\#(snapshot.count),"data":\#(rows)}"#)

        case "/v2/dm/models":
            return .json(#"[{"id":"m1","name":"SIP-T54S"},{"id":"m2","name":"SIP-T31P"}]"#)

        case "/v2/dm/listSites":
            return .json(#"{"skip":0,"limit":100,"total":1,"data":[{"id":"s1","name":"Head Office","parentId":null}]}"#)

        default:
            return .json(#"{"message":"unhandled \#(path)"}"#, status: 404)
        }
    }
}

extension Device {
    static func stub(_ id: String, _ status: DeviceStatus, name: String? = nil) -> Device {
        Device(
            id: id,
            mac: "0015650000" + String(format: "%02x", abs(id.hashValue % 256)),
            name: name ?? "Phone \(id)",
            modelId: "m1",
            siteId: "s1",
            deviceStatus: status
        )
    }
}

extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
