import Foundation

/// Works out what a diagnostic download actually is.
///
/// The API document describes what these endpoints return and is wrong about
/// it: `exportSyslog` is documented as producing a text file and delivers a zip
/// containing `datalog/*.log` plus a nested `systemlog.zip`. The download URL
/// carries no useful content type either, so the leading bytes are the only
/// thing worth trusting -- and getting this wrong writes a zip to disk named
/// `.txt`, which opens as pages of mojibake and looks like a corrupt or
/// encrypted file.
public enum DiagnosticPayload {
    /// The file extension the bytes call for, or `fallback` when they look like
    /// ordinary text.
    public static func fileExtension(for data: Data, fallback: String) -> String {
        switch Array(data.prefix(4)) {
        case [0x50, 0x4B, 0x03, 0x04], [0x50, 0x4B, 0x05, 0x06]:
            return "zip"
        case [0x89, 0x50, 0x4E, 0x47]:
            return "png"
        case [0xD4, 0xC3, 0xB2, 0xA1], [0xA1, 0xB2, 0xC3, 0xD4]:
            return "pcap"
        case [0x0A, 0x0D, 0x0D, 0x0A]:
            return "pcapng"
        default:
            break
        }
        if data.prefix(3).elementsEqual([0xFF, 0xD8, 0xFF]) { return "jpg" }
        // No signature recognised. Trust the caller's guess only if the content
        // really does decode as text; otherwise say plainly that it is binary
        // rather than mislabelling it.
        return isProbablyText(data) ? fallback : "bin"
    }

    /// True when the payload can be shown to the user as text.
    ///
    /// Checked on a prefix: a multi-megabyte log should not be decoded twice,
    /// and the first few kilobytes settle it. A prefix that splits a multi-byte
    /// character would fail the decode, so the boundary is walked back a little
    /// before giving up.
    public static func isProbablyText(_ data: Data) -> Bool {
        guard !data.isEmpty else { return true }
        let sample = data.prefix(4096)
        // A NUL byte in the first few kilobytes means binary, whatever else
        // decodes.
        if sample.contains(0) { return false }
        for trim in 0..<4 where sample.count > trim {
            if String(data: sample.dropLast(trim), encoding: .utf8) != nil { return true }
        }
        return false
    }
}
