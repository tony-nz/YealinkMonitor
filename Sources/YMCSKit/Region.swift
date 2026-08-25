import Foundation

/// A YMCS deployment region. Each region is a physically separate service with
/// its own hostname; credentials issued for one region do not work against
/// another, which is why authentication failures and wrong-region errors look
/// so similar during first-time setup.
public enum Region: String, CaseIterable, Sendable, Codable {
    case au
    case eu
    case us

    public var host: String { "\(rawValue)-api.ymcs.yealink.com" }

    public var displayName: String {
        switch self {
        case .au: "Australia / APAC"
        case .eu: "Europe"
        case .us: "United States"
        }
    }

    public var baseURL: URL { URL(string: "https://\(host)")! }

    /// Order to probe when the user does not know their region. AU first: this
    /// project's user is in New Zealand.
    public static let probeOrder: [Region] = [.au, .eu, .us]
}
