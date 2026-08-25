import Foundation
import Testing
@testable import YMCSKit

@Suite("Models")
struct ModelTests {
    @Test("MAC addresses are colon-separated for display")
    func macFormatting() {
        #expect(Device.formatMAC("001565bbb1a9") == "00:15:65:BB:B1:A9")
        #expect(Device.formatMAC("00:15:65:bb:b1:a9") == "00:15:65:BB:B1:A9")
        // Anything that is not 12 hex digits is passed through untouched rather
        // than mangled.
        #expect(Device.formatMAC("nonsense") == "nonsense")
    }

    @Test("Unnamed devices fall back to their MAC")
    func displayNameFallback() {
        let named = Device(id: "1", mac: "001565bbb1a9", name: "Reception", deviceStatus: .online)
        let unnamed = Device(id: "2", mac: "001565bbb1a9", name: "", deviceStatus: .online)
        #expect(named.displayName == "Reception")
        #expect(unnamed.displayName == "00:15:65:BB:B1:A9")
    }

    @Test("Device status round-trips, and unrecognised values are preserved")
    func statusDecoding() throws {
        let decoded = try JSONDecoder().decode(
            [DeviceStatus].self,
            from: Data(#"["online","offline","pending","something-new"]"#.utf8)
        )
        #expect(decoded == [.online, .offline, .pending, .unknown("something-new")])
        #expect(decoded[3].rawValue == "something-new")
        // An unknown status has no filter representation, so it can never be
        // silently sent to the server as some other status.
        #expect(decoded[3].filterValue == nil)
        #expect(DeviceStatus.online.filterValue == 1)
        #expect(DeviceStatus.offline.filterValue == 0)
        #expect(DeviceStatus.pending.filterValue == -1)
    }

    @Test("Device list fixture decodes, including null-heavy rows")
    func deviceListDecoding() throws {
        let page = try JSONDecoder().decode(Page<Device>.self, from: Fixture.data("listDevices"))
        #expect(page.total == 3)
        #expect(page.items.count == 3)
        #expect(page.items[0].deviceStatus == .online)
        #expect(page.items[1].deviceStatus == .offline)
        // A pending device with no name, SN or firmware must still decode.
        #expect(page.items[2].deviceStatus == .pending)
        #expect(page.items[2].name == nil)
        #expect(page.items[2].displayName == "00:15:65:BB:B1:AB")
    }

    @Test("Detail exposes SIP line health and report staleness")
    func deviceDetailDecoding() throws {
        let detail = try JSONDecoder().decode(DeviceDetail.self, from: Fixture.data("deviceDetail"))
        #expect(detail.lanIp == "10.50.198.156")
        #expect(detail.modelName == "SIP-T54S")
        #expect(detail.accounts?.count == 2)
        #expect(detail.accounts?[0].status == .registered)
        // Line 2 is unregistered while the device itself is online: the case
        // the UI has to surface separately.
        #expect(detail.deviceStatus == .online)
        #expect(detail.accounts?[1].status == .unregistered)
        #expect(detail.accounts?[1].status?.isHealthy == false)
        #expect(detail.lastReportDate == Date(timeIntervalSince1970: 1_737_082_468.768))
    }

    @Test("Alarms decode with their own timestamps")
    func alarmDecoding() throws {
        let page = try JSONDecoder().decode(Page<Alarm>.self, from: Fixture.data("alarms"))
        let alarm = try #require(page.items.first)
        #expect(alarm.event == "Offline")
        #expect(alarm.level == .critical)
        #expect(alarm.status == .active)
        #expect(alarm.firstAlarmDate != alarm.lastAlarmDate)
    }

    @Test("Error bodies decode into something showable")
    func errorBodyDecoding() throws {
        let body = try JSONDecoder().decode(APIErrorBody.self, from: Fixture.data("error401"))
        #expect(body.message == "Invalid client credentials")
        #expect(body.details?.first?.field == "client_id")
    }

    @Test("An empty filter is distinguishable from a populated one")
    func filterEmptiness() {
        #expect(DeviceFilter().isEmpty)
        #expect(!DeviceFilter(status: .offline).isEmpty)
        #expect(DeviceFilter(status: .offline).deviceStatus == 0)
    }

    @Test("Region hosts match the documented endpoints")
    func regionHosts() {
        #expect(Region.au.host == "au-api.ymcs.yealink.com")
        #expect(Region.eu.host == "eu-api.ymcs.yealink.com")
        #expect(Region.us.host == "us-api.ymcs.yealink.com")
        #expect(Region.probeOrder.first == .au)
    }
}
