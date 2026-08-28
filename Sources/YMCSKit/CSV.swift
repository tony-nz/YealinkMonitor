import Foundation

/// Renders rows as RFC 4180 CSV.
///
/// Small enough to write by hand, and worth writing rather than joining strings
/// with commas: device names contain commas ("Office, Spare" is an ordinary
/// name for a phone), sites contain quotes, and getting the escaping wrong
/// produces a file that opens misaligned in Excel rather than one that fails
/// loudly.
public enum CSV {
    /// The rendered document, ready to write to disk.
    ///
    /// - Parameter byteOrderMark: prepends a UTF-8 BOM. Excel on both Windows
    ///   and macOS otherwise reads the file as the system's legacy encoding and
    ///   mangles anything non-ASCII -- macrons in New Zealand place names, for
    ///   one.
    public static func document(
        header: [String],
        rows: [[String]],
        byteOrderMark: Bool = true
    ) -> Data {
        var text = ([header] + rows)
            .map { line($0) }
            .joined(separator: "\r\n")
        // A trailing newline: some parsers drop the final row without it.
        text += "\r\n"

        var data = byteOrderMark ? Data([0xEF, 0xBB, 0xBF]) : Data()
        data.append(Data(text.utf8))
        return data
    }

    static func line(_ fields: [String]) -> String {
        fields.map(field).joined(separator: ",")
    }

    /// Quotes only when required, so an ordinary file stays readable.
    static func field(_ value: String) -> String {
        let needsQuoting = value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" })
            // Leading or trailing spaces are silently trimmed by some readers.
            || value.hasPrefix(" ")
            || value.hasSuffix(" ")
        guard needsQuoting else { return value }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
