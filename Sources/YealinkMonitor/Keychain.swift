import Foundation
import Security
import YMCSKit

/// Stores the YMCS client secret in the login keychain.
///
/// The secret is a long-lived credential for the whole enterprise, so it never
/// goes near UserDefaults, a plist or a log line.
enum Keychain {
    static let service = "nz.co.myers.YealinkMonitor"
    static let account = "ymcs-client-secret"

    enum Failure: Error, LocalizedError {
        case status(OSStatus)

        var errorDescription: String? {
            switch self {
            case .status(let status):
                let message = SecCopyErrorMessageString(status, nil) as String?
                return message ?? "Keychain error \(status)"
            }
        }
    }

    static func readSecret() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw Failure.status(status)
        }
    }

    static func writeSecret(_ secret: String) throws {
        guard !secret.isEmpty else {
            try deleteSecret()
            return
        }
        let data = Data(secret.utf8)
        let status = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecSuccess { return }
        if status == errSecItemNotFound {
            var query = baseQuery
            query[kSecValueData as String] = data
            // Available after first unlock so the app can poll after a reboot
            // without the user having to open it first.
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw Failure.status(addStatus) }
            return
        }
        throw Failure.status(status)
    }

    static func deleteSecret() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Failure.status(status)
        }
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// Reads the Client ID from settings and the secret from the keychain.
struct KeychainCredentialsProvider: CredentialsProviding {
    let clientID: String
    let region: Region

    func credentials() async throws -> Credentials {
        // `try?` flattens the throwing Optional return, so a missing item and a
        // keychain error are both simply "not configured" here.
        guard !clientID.isEmpty,
              let secret = try? Keychain.readSecret(),
              !secret.isEmpty
        else {
            throw YMCSError.notConfigured
        }
        return Credentials(clientID: clientID, clientSecret: secret, region: region)
    }
}
