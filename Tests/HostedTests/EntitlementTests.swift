import Foundation
import Security
import XCTest

/// Checks that the app's phase 7 entitlements reach the simulator build (design section 9, round 3a, question 1).
/// The tests run inside the app, because the Keychain and the App Group answer by the host's entitlements.
final class EntitlementTests: XCTestCase {
    /// An item added without an access group lands in the app's default group. With `keychain-access-groups` that is
    /// the shared group `<team>.dev.lastide.app.shared`, which the notification service extension also holds.
    func testAnItemWithoutAGroupLandsInTheSharedKeychainGroup() throws {
        let service = "lastide.hosted-test"
        let account = UUID().uuidString
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data([1, 2, 3]),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemAdd(item as CFDictionary, &result)
        XCTAssertEqual(status, errSecSuccess, "SecItemAdd failed with status \(status)")
        defer {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            SecItemDelete(query as CFDictionary)
        }
        let attributes = try XCTUnwrap(result as? [String: Any], "SecItemAdd returned no attributes")
        let group = try XCTUnwrap(attributes[kSecAttrAccessGroup as String] as? String, "the item has no access group")
        XCTAssertTrue(group.hasSuffix("dev.lastide.app.shared"), "the default access group is not the shared group")
    }

    /// The App Group container exists, so the app, the extension and the widget can share files.
    func testTheAppGroupContainerExists() {
        XCTAssertNotNil(FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.dev.lastide.app"))
    }
}
