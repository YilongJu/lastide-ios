import Foundation
import Security

/// The Keychain move of the first phase 7 launch (design section 6.2).
///
/// Builds before phase 7 kept each item of the service `lastide.pairing` in the app's own access group. The move copies
/// each item outside the shared group into it, with the same accessibility and the same synchronizable value, reads the
/// copy back, and only then deletes the old item. A crash between the copy and the delete leaves two copies, and the
/// next run finds the shared copy and deletes the other.
enum KeychainMove {
    struct Failure: Error, CustomStringConvertible {
        let operation: String
        let status: OSStatus
        var description: String { "Keychain move: \(operation) failed with status \(status)" }
    }

    /// What one run did.
    struct Report: Equatable, Sendable {
        /// Items copied into the shared group, then deleted from their old group.
        var moved = 0
        /// Items whose shared copy already existed, deleted from their old group.
        var duplicatesRemoved = 0
    }

    /// Moves every item of `service` that lies outside `group` into `group`.
    static func run(service: String, into group: String) throws -> Report {
        var report = Report()
        for item in try listItems(service: service) {
            guard let account = item[kSecAttrAccount as String] as? String,
                  let oldGroup = item[kSecAttrAccessGroup as String] as? String,
                  oldGroup != group
            else { continue }
            let accessible = item[kSecAttrAccessible as String] ?? kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let synchronizable = (item[kSecAttrSynchronizable as String] as? Bool) ?? false
            guard let value = try read(service: service, account: account, group: oldGroup, synchronizable: synchronizable)
            else { continue }
            if let copy = try read(service: service, account: account, group: group, synchronizable: synchronizable) {
                guard copy == value else {
                    throw Failure(operation: "compare the two copies of \(account)", status: errSecDuplicateItem)
                }
                try delete(service: service, account: account, group: oldGroup, synchronizable: synchronizable)
                report.duplicatesRemoved += 1
                continue
            }
            let add: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecAttrAccessGroup as String: group,
                kSecValueData as String: value,
                kSecAttrAccessible as String: accessible,
                kSecAttrSynchronizable as String: synchronizable,
            ]
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecSuccess else { throw Failure(operation: "add the copy of \(account)", status: status) }
            guard try read(service: service, account: account, group: group, synchronizable: synchronizable) == value else {
                throw Failure(operation: "read back the copy of \(account)", status: errSecItemNotFound)
            }
            try delete(service: service, account: account, group: oldGroup, synchronizable: synchronizable)
            report.moved += 1
        }
        return report
    }

    /// Every item of `service` in every access group the process holds, with its attributes.
    private static func listItems(service: String) throws -> [[String: Any]] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            throw Failure(operation: "list the items of \(service)", status: status)
        }
        return items
    }

    private static func read(service: String, account: String, group: String, synchronizable: Bool) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: group,
            kSecAttrSynchronizable as String: synchronizable,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw Failure(operation: "read \(account)", status: status)
        }
        return data
    }

    private static func delete(service: String, account: String, group: String, synchronizable: Bool) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: group,
            kSecAttrSynchronizable as String: synchronizable,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess else { throw Failure(operation: "delete the old \(account)", status: status) }
    }
}
