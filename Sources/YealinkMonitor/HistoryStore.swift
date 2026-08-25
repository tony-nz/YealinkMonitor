import Foundation
import YMCSKit

/// A capped, on-disk log of confirmed status changes.
///
/// Answers the question the API cannot: "how often does this phone actually
/// drop?" YMCS alarms only describe currently-active problems.
@MainActor
final class HistoryStore {
    /// Enough for months of a normal fleet, small enough to load instantly.
    private static let limit = 2000

    private(set) var entries: [StatusChange] = []
    private let url: URL

    init(url: URL? = nil) {
        self.url = url ?? Self.defaultURL()
        load()
    }

    static func defaultURL() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL.temporaryDirectory
        let directory = base.appending(path: "YealinkMonitor", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "history.json")
    }

    func append(_ change: StatusChange) {
        entries.append(change)
        if entries.count > Self.limit {
            entries.removeFirst(entries.count - Self.limit)
        }
        save()
    }

    func entries(forDeviceID id: String) -> [StatusChange] {
        entries.filter { $0.device.id == id }.reversed()
    }

    /// Most recent first.
    var recent: [StatusChange] {
        entries.reversed()
    }

    func clear() {
        entries = []
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // A corrupt or outdated history file must never stop the app starting;
        // the history is a convenience, not the product.
        entries = (try? decoder.decode([StatusChange].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
