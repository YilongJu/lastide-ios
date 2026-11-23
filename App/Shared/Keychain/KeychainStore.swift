import Foundation
import LastideKit
import Security

/// The phone's secrets, one Keychain item per pairing and field (protocol section 2.3).
protocol SecretStore: Sendable {
    func save(_ value: Data, account: String) throws
    func load(account: String) throws -> Data?
    func delete(account: String) throws
    /// Every account under the service `lastide.pairing`.
    func allAccounts() throws -> [String]
}

/// The Keychain account names of one pairing: `<pairing id>.key` and `<pairing id>.token`.
enum SecretAccount {
    static func key(_ id: PairingID) -> String { id.base64url + ".key" }
    static func token(_ id: PairingID) -> String { id.base64url + ".token" }
    /// The pairing id an account name starts with.
    static func pairingID(of account: String) -> String { String(account.prefix { $0 != "." }) }
}

/// The phone's secrets as Keychain items in one access group (protocol section 2.3, design section 6.2).
/// Each item has class `kSecClassGenericPassword`, service `lastide.pairing` and account `<pairing id>.<field>`.
/// Each item opens after the first unlock, stays on this device and stays out of iCloud Keychain.
/// The app and the notification service extension compile this file. The widget does not.
struct KeychainStore: SecretStore {
    static let service = "lastide.pairing"

    struct Failure: Error, CustomStringConvertible {
        let operation: String
        let status: OSStatus
        var description: String { "Keychain \(operation) failed with status \(status)" }
    }

    /// The shared group `<team>.dev.lastide.app.shared`. Every query names it.
    let accessGroup: String

    func save(_ value: Data, account: String) throws {
        try delete(account: account)
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecValueData as String: value,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure(operation: "add", status: status) }
    }

    func load(account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw Failure(operation: "read", status: status) }
        return data
    }

    func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(operation: "delete", status: status) }
    }

    func allAccounts() throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccessGroup as String: accessGroup,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            throw Failure(operation: "list", status: status)
        }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }
}

/// Finds the shared access group `<team>.dev.lastide.app.shared` at run time, so no file of this public repository
/// holds the Team ID.
///
/// Apple's page "Sharing access to keychain items among a collection of apps" says the first group of
/// `keychain-access-groups` is the default group of an item added without one. The app and the extension both list the
/// shared group first. So the group of a probe item added without a group names the shared group.
enum KeychainGroup {
    /// The last part of the shared group, after the Team ID and a dot.
    static let suffix = "dev.lastide.app.shared"
    private static let probeService = "lastide.group-probe"
    private static let probeAccount = "default-group"

    /// The build lacks the shared group, or the Keychain refused the probe.
    struct Failure: Error, CustomStringConvertible {
        let detail: String
        var description: String { "the shared Keychain group is not available: \(detail)" }
    }

    /// The shared group. Reads the probe item, or adds it the first time.
    static func shared() throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: probeService,
            kSecAttrAccount as String: probeAccount,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        var status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            let item: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: probeService,
                kSecAttrAccount as String: probeAccount,
                kSecValueData as String: Data(),
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
                kSecReturnAttributes as String: true,
            ]
            status = SecItemAdd(item as CFDictionary, &result)
        }
        guard status == errSecSuccess else { throw Failure(detail: "status \(status)") }
        guard let attributes = result as? [String: Any], let group = attributes[kSecAttrAccessGroup as String] as? String else {
            throw Failure(detail: "the probe item has no access group")
        }
        guard group == suffix || group.hasSuffix("." + suffix) else {
            throw Failure(detail: "the default access group is not the shared group")
        }
        return group
    }
}
