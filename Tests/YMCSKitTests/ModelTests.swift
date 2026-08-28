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

@Suite("Call records")
struct CallRecordTests {
    private func decode(_ json: String) throws -> CallRecord {
        try JSONDecoder().decode(CallRecord.self, from: Data(json.utf8))
    }

    @Test("Duration prefers the timestamps over the ambiguous duration field")
    func durationFromTimestamps() throws {
        let call = try decode(#"""
        {"id":"1","startTime":1787874266000,"endTime":1787874307000,"duration":41}
        """#)
        #expect(call.durationSeconds == 41)
    }

    @Test("Duration falls back to the field when a timestamp is missing")
    func durationFallback() throws {
        let call = try decode(#"{"id":"1","startTime":1787874266000,"duration":41}"#)
        #expect(call.durationSeconds == 41)
    }

    @Test("A call with no timing at all reports no duration")
    func durationAbsent() throws {
        #expect(try decode(#"{"id":"1"}"#).durationSeconds == nil)
    }

    @Test("MOS takes the worse measured direction and ignores unmeasured ones")
    func mosIgnoresZero() throws {
        // 0 means "not measured", not "unusable" -- averaging it in would report
        // every one-way-measured call as terrible.
        let oneWay = try decode(#"{"id":"1","inConversationalMosAvg":4.3,"outConversationalMosAvg":0.0}"#)
        #expect(oneWay.mos == 4.3)

        let twoWay = try decode(#"{"id":"1","inConversationalMosAvg":4.3,"outConversationalMosAvg":3.1}"#)
        #expect(twoWay.mos == 3.1)

        #expect(try decode(#"{"id":"1"}"#).mos == nil)
        #expect(try decode(#"{"id":"1","inConversationalMosAvg":0.0}"#).mos == nil)
    }

    @Test("Quality decodes whatever case the server sends")
    func qualityCase() throws {
        #expect(try decode(#"{"id":"1","quality":"GOOD"}"#).quality == .good)
        #expect(try decode(#"{"id":"1","quality":"Poor"}"#).quality == .poor)
        #expect(try decode(#"{"id":"1","quality":"bad"}"#).quality?.isPoor == true)
        #expect(try decode(#"{"id":"1","quality":"weird"}"#).quality == .unknown)
    }
}

@Suite("Diagnostic payloads")
struct DiagnosticPayloadTests {
    private func data(_ bytes: [UInt8]) -> Data { Data(bytes) }

    @Test("A zip is recognised however the endpoint describes itself")
    func recognisesZip() {
        // exportSyslog is documented as text and returns this. Naming it .txt
        // is what makes an ordinary log look like an encrypted file.
        let zip = data([0x50, 0x4B, 0x03, 0x04]) + Data("datalog/".utf8)
        #expect(DiagnosticPayload.fileExtension(for: zip, fallback: "txt") == "zip")

        let emptyZip = data([0x50, 0x4B, 0x05, 0x06])
        #expect(DiagnosticPayload.fileExtension(for: emptyZip, fallback: "txt") == "zip")
    }

    @Test("Image and capture formats are recognised")
    func recognisesOtherFormats() {
        #expect(DiagnosticPayload.fileExtension(for: data([0x89, 0x50, 0x4E, 0x47]), fallback: "png") == "png")
        #expect(DiagnosticPayload.fileExtension(for: data([0xFF, 0xD8, 0xFF, 0xE0]), fallback: "png") == "jpg")
        #expect(DiagnosticPayload.fileExtension(for: data([0xD4, 0xC3, 0xB2, 0xA1]), fallback: "pcap") == "pcap")
        #expect(DiagnosticPayload.fileExtension(for: data([0x0A, 0x0D, 0x0D, 0x0A]), fallback: "pcap") == "pcapng")
    }

    @Test("Real text keeps the extension the caller expected")
    func keepsFallbackForText() {
        let log = Data("Aug 28 11:54:22 sua [1156.1277]: DLG <6+info> User-Agent: Yealink SIP-T30P\n".utf8)
        #expect(DiagnosticPayload.fileExtension(for: log, fallback: "txt") == "txt")
        #expect(DiagnosticPayload.isProbablyText(log))
    }

    @Test("Unrecognised binary is labelled binary rather than mislabelled text")
    func unknownBinary() {
        let binary = data([0x00, 0x01, 0x02, 0x03, 0x00, 0xFF])
        #expect(DiagnosticPayload.fileExtension(for: binary, fallback: "txt") == "bin")
        #expect(!DiagnosticPayload.isProbablyText(binary))
    }

    @Test("A multi-byte character split by the sample boundary is still text")
    func textAcrossSampleBoundary() {
        // 4096 bytes of ASCII then a macron, so the prefix ends mid-character.
        let padded = Data(String(repeating: "a", count: 4095).utf8) + Data("Ōtāhuhu".utf8)
        #expect(DiagnosticPayload.isProbablyText(padded))
    }

    @Test("An empty payload is not treated as binary")
    func emptyPayload() {
        #expect(DiagnosticPayload.isProbablyText(Data()))
        #expect(DiagnosticPayload.fileExtension(for: Data(), fallback: "txt") == "txt")
    }
}

@Suite("CSV")
struct CSVTests {
    private func text(_ data: Data) -> String {
        // Drop the BOM so assertions read normally.
        String(decoding: data.dropFirst(3), as: UTF8.self)
    }

    @Test("Ordinary values are not quoted")
    func plainValues() {
        #expect(CSV.field("Reception") == "Reception")
        #expect(CSV.line(["a", "b"]) == "a,b")
    }

    @Test("A comma in a device name does not shift every later column")
    func quotesCommas() {
        // "Office, Spare" is an entirely ordinary name for a phone.
        #expect(CSV.field("Office, Spare") == "\"Office, Spare\"")
    }

    @Test("Quotes are doubled, as RFC 4180 requires")
    func escapesQuotes() {
        #expect(CSV.field("The \"Old\" Hall") == "\"The \"\"Old\"\" Hall\"")
    }

    @Test("Newlines inside a field are kept rather than breaking the row")
    func quotesNewlines() {
        #expect(CSV.field("line1\nline2") == "\"line1\nline2\"")
    }

    @Test("Padding spaces are preserved by quoting them")
    func quotesEdgeWhitespace() {
        #expect(CSV.field(" leading") == "\" leading\"")
        #expect(CSV.field("trailing ") == "\"trailing \"")
    }

    @Test("The document has a header, CRLF rows and a trailing newline")
    func documentShape() {
        let data = CSV.document(header: ["Name", "MAC"], rows: [["Reception", "00:15:65"]])
        #expect(text(data) == "Name,MAC\r\nReception,00:15:65\r\n")
    }

    @Test("A UTF-8 BOM is written so Excel does not mangle macrons")
    func byteOrderMark() {
        let data = CSV.document(header: ["Site"], rows: [["Ōtāhuhu"]])
        #expect(data.prefix(3) == Data([0xEF, 0xBB, 0xBF]))
        #expect(text(data).contains("Ōtāhuhu"))

        let without = CSV.document(header: ["Site"], rows: [], byteOrderMark: false)
        #expect(without.prefix(3) != Data([0xEF, 0xBB, 0xBF]))
    }

    @Test("A header with no rows is still a valid document")
    func headerOnly() {
        #expect(text(CSV.document(header: ["Name"], rows: [])) == "Name\r\n")
    }
}
