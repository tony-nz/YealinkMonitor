import Foundation
@testable import YMCSKit

/// A minimal in-memory stand-in for YMCS: enough of `/v2/token`,
/// `listDevices`, `deviceCount`, `models`, `listSites` and `listAlarms` to
/// drive the Monitor through realistic scenarios.
final class FakeServer: @unchecked Sendable {
    private let lock = NSLock()
    private var _devices: [Device]
    private var _counts: [String: Int] = [:]
    private var _failWith: HTTPResponse?
    private var _failRemaining = 0
    private var _alarms: [Alarm] = []
    private var _alarmStatus: Int?
    private var _rebootRequests: [[String: Any]] = []
    private var _rebootFailures: Set<String> = []
    private var _accessories: [Accessory] = []
    private var _diagnosticRequests: [(path: String, body: [String: Any])] = []
    private var _requestBodies: [String: [[String: Any]]] = [:]
    private var _pollsBeforeSuccess = 0
    private var _diagnosticState = "success"

    init(devices: [Device] = [], alarms: [Alarm] = [], accessories: [Accessory] = []) {
        self._devices = devices
        self._alarms = alarms
        self._accessories = accessories
    }

    var accessories: [Accessory] {
        get { lock.withLock { _accessories } }
        set { lock.withLock { _accessories = newValue } }
    }

    var alarms: [Alarm] {
        get { lock.withLock { _alarms } }
        set { lock.withLock { _alarms = newValue } }
    }

    /// Makes `listAlarms` fail with this status while everything else succeeds.
    func failAlarms(with status: Int) {
        lock.withLock { _alarmStatus = status }
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

    /// Every body posted to `/v2/dm/device/reboot`, in order.
    var rebootRequests: [[String: Any]] {
        lock.withLock { _rebootRequests }
    }

    /// Device ids the reboot endpoint should report in `errors[]` rather than
    /// restarting.
    func rejectReboots(of ids: [String]) {
        lock.withLock { _rebootFailures = Set(ids) }
    }

    /// Every diagnostic start request, as (path, body).
    var diagnosticRequests: [(path: String, body: [String: Any])] {
        lock.withLock { _diagnosticRequests }
    }

    /// Makes the status endpoint report `inprogress` this many times before it
    /// succeeds.
    func reportInProgress(times: Int) {
        lock.withLock { _pollsBeforeSuccess = times }
    }

    /// Makes the diagnostic finish in this state.
    func finishDiagnostics(as state: String) {
        lock.withLock { _diagnosticState = state }
    }

    /// Bodies posted to one path, in order.
    func bodies(for path: String) -> [[String: Any]] {
        lock.withLock { _requestBodies[path] ?? [] }
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

        if let body = request.jsonBody {
            lock.withLock { _requestBodies[path, default: []].append(body) }
        }

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
            // Real YMCS returns a disjoint set per type, and the app relies on
            // that to work out a device's type at all.
            let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let type = query.first { $0.name == "deviceType" }?.value
            return type == "3"
                ? .json(#"[{"id":"m9","name":"MeetingBar A20"}]"#)
                : .json(#"[{"id":"m1","name":"SIP-T54S"},{"id":"m2","name":"SIP-T31P"}]"#)

        case _ where path.hasSuffix("/networkInterfaces"):
            return .json(#"["wan","wlan0","ext0"]"#)

        case _ where path.hasPrefix("/v2/dm/diagnosis/"):
            let remaining: Int = lock.withLock {
                defer { if _pollsBeforeSuccess > 0 { _pollsBeforeSuccess -= 1 } }
                return _pollsBeforeSuccess
            }
            if remaining > 0 {
                return .json(#"{"deviceId":"1","status":"inprogress"}"#)
            }
            let state = lock.withLock { _diagnosticState }
            if state != "success" {
                return .json(#"{"deviceId":"1","status":"\#(state)"}"#)
            }
            return .json(#"{"deviceId":"1","status":"success","url":"https://example.com/log.txt"}"#)

        case _ where ["/captureScreen", "/exportSyslog", "/exportConfig", "/ping", "/traceroute", "/startPacketCapture", "/stopPacketCapture"].contains(where: { path.hasSuffix($0) }):
            lock.withLock { _diagnosticRequests.append((path, request.jsonBody ?? [:])) }
            return .json(#"{"diagnosisId":"diag-1"}"#)

        case _ where path.hasPrefix("/v2/dm/devices/") && path.split(separator: "/").count == 4:
            let id = String(path.split(separator: "/").last ?? "")
            guard let device = snapshot.first(where: { $0.id == id }) else {
                return .json(#"{"message":"no such device"}"#, status: 404)
            }
            // The detail endpoint is the only one that returns a LAN IP.
            return .json(#"{"id":"\#(device.id)","mac":"\#(device.mac)","sn":"SN\#(device.id)","name":"\#(device.name ?? "")","lanIp":"10.42.0.\#(device.id)","deviceStatus":"\#(device.deviceStatus.rawValue)","programVersion":"\#(device.programVersion ?? "")","lastReportTime":1787874266000}"#)

        case "/v2/dm/listQoes":
            // Mirrors a real response: quality uppercased, both URIs null,
            // duration in seconds despite the document saying milliseconds.
            return .json(#"{"skip":0,"limit":10,"total":1,"data":[{"id":"q1","deviceName":"Reception","mac":"001565bbb1a9","modelName":"SIP-T87W","username":"5551234","siteName":"Head Office","quality":"GOOD","startTime":1787874266000,"endTime":1787874307000,"callerURI":null,"calleeURI":null,"duration":41,"inConversationalMosAvg":4.3,"outConversationalMosAvg":0.0}]}"#)

        case "/v2/dm/statistics/qoe":
            return .json(#"{"total":100,"badTotal":7,"badPercentage":7.0,"goodPercentage":93.0}"#)

        case "/v2/dm/listOpLogs":
            // Spelled as the API document's worked example spells it.
            return .json(#"{"skip":0,"limit":10,"total":1,"data":[{"module":"i18n.yiot.backend.module.device.management","operationTypetype":"i18n.yiot.backend.operation.device.management.restart","operationObject":"805ec0985cd2","operator":"tony","ip":"10.0.0.5","createTime":1700000000000,"result":"success"}]}"#)

        case "/v2/dm/device/listParts":
            let body = request.jsonBody ?? [:]
            let wanted = Set(body["deviceIds"] as? [String] ?? [])
            let matching = accessories.filter { wanted.contains($0.parentId ?? "") }
            // Deliberately a bare array, and with connStatus quoted, because
            // that is what the batch endpoint actually returns.
            let rows = matching.map { part in
                #"{"id":"\#(part.id)","parentId":"\#(part.parentId ?? "")","modelName":"\#(part.modelName ?? "")","connStatus":"\#(part.connStatus?.rawValue ?? 1)"}"#
            }.joined(separator: ",")
            return .json("[" + rows + "]")

        case "/v2/dm/device/reboot":
            let body = request.jsonBody ?? [:]
            lock.withLock { _rebootRequests.append(body) }
            let ids = body["deviceIds"] as? [String] ?? []
            let rejected = lock.withLock { _rebootFailures }
            let failed = ids.filter { rejected.contains($0) }
            let errors = failed
                .map { #"{"field":"\#($0)","msg":"The resource does not exist or has been deleted"}"# }
                .joined(separator: ",")
            return .json(#"{"total":\#(ids.count),"successCount":\#(ids.count - failed.count),"failureCount":\#(failed.count),"errors":[\#(errors)]}"#)

        case "/v2/dm/listAlarms":
            if let status = lock.withLock({ _alarmStatus }) {
                return .json(#"{"message":"alarms unavailable"}"#, status: status)
            }
            let body = request.jsonBody ?? [:]
            let skip = body["skip"] as? Int ?? 0
            let limit = body["limit"] as? Int ?? 10
            let all = alarms
            let slice = Array(all.dropFirst(skip).prefix(limit))
            let rows = (try? JSONEncoder().encode(slice)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            return .json(#"{"skip":\#(skip),"limit":\#(limit),"total":\#(all.count),"data":\#(rows)}"#)

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

extension Device {
    static func stubFirmware(_ id: String, _ version: String, model: String = "m1") -> Device {
        let base = Device.stub(id, .online)
        return Device(
            id: base.id, mac: base.mac, sn: base.sn, name: base.name,
            modelId: model, siteId: base.siteId,
            programVersion: version, deviceStatus: base.deviceStatus
        )
    }
}

extension Alarm {
    static func stub(
        _ id: String,
        mac: String,
        event: String = "Offline",
        level: Level = .critical,
        status: Status = .active,
        first: Int64 = 1_737_082_468_768
    ) -> Alarm {
        Alarm(
            id: id, event: event, level: level, mac: mac, model: "SIP-T54S",
            ip: "10.0.0.1", siteName: "Head Office", status: status,
            firstAlarmTime: first, lastAlarmTime: first
        )
    }
}

extension Accessory {
    static func stub(_ id: String, parent: String, model: String = "EXP50", status: ConnectionStatus = .online) -> Accessory {
        Accessory(id: id, parentId: parent, modelName: model, connStatus: status)
    }
}

extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
