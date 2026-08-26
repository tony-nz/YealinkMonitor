import Foundation
import YMCSKit

/// Credentials baked into the bundle at build time by `make-app.sh --embed`.
///
/// This exists so a bundle can be copied to another Mac and just work, with no
/// provisioning step. The cost is real and worth stating plainly: anything in
/// Info.plist is readable by anyone holding the bundle, and the YMCS AccessKey
/// authorises device restart, factory reset and firmware push across the whole
/// enterprise. An embedded build is a credential you are handing out, not
/// merely an app.
///
/// Absent unless the build explicitly asked for it, so an ordinary build ships
/// with nothing in it.
enum EmbeddedCredentials {
    private enum Key {
        static let clientID = "YMCSClientID"
        static let clientSecret = "YMCSClientSecret"
        static let region = "YMCSRegion"
    }

    struct Values {
        let clientID: String
        let clientSecret: String
        let region: Region?
    }

    static var current: Values? {
        guard let clientID = value(for: Key.clientID),
              let clientSecret = value(for: Key.clientSecret)
        else { return nil }
        return Values(
            clientID: clientID,
            clientSecret: clientSecret,
            region: value(for: Key.region).flatMap(Region.init(rawValue:))
        )
    }

    private static func value(for key: String) -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !raw.isEmpty
        else { return nil }
        return raw
    }
}
