import Foundation
@testable import Lastide
import LastideKit
import UserNotifications
import XCTest

/// Design Table 21, check U2: the two categories hold Table 15's ids, titles and options.
final class CategoryTests: XCTestCase {
    func testU2TheTwoCategoriesHoldTable15() throws {
        let categories = NotificationCategories.make()
        XCTAssertEqual(Set(categories.map(\.identifier)), ["PROPOSED_RULE", "LASTIDE_PLAIN"])
        let rule = try XCTUnwrap(categories.first { $0.identifier == "PROPOSED_RULE" })
        XCTAssertEqual(rule.actions.map(\.identifier), ["APPROVE", "DELETE", "OPEN"])
        XCTAssertEqual(rule.actions.map(\.title), ["Approve", "Delete", "Open"])
        XCTAssertEqual(rule.actions.map(\.options), [[.authenticationRequired], [.destructive, .authenticationRequired],
                                                     [.foreground]])
        XCTAssertEqual(rule.hiddenPreviewsBodyPlaceholder, "A rule waits for your review.")
        let plain = try XCTUnwrap(categories.first { $0.identifier == "LASTIDE_PLAIN" })
        XCTAssertEqual(plain.actions.map(\.identifier), ["OPEN"])
        XCTAssertEqual(plain.actions.map(\.title), ["Open"])
        XCTAssertEqual(plain.actions.map(\.options), [[.foreground]])
        XCTAssertEqual(plain.hiddenPreviewsBodyPlaceholder, "A rule waits for your review.")
    }
}

/// Design Table 21, check U3: the Keychain move on the host's real Keychain.
///
/// Apple's page says the first `keychain-access-groups` entry is the default group, so an item added without a group
/// lands in the shared group already. The test therefore adds its item to the App Group, which the host holds as a
/// Keychain group outside the shared one, reads that group back, and runs the move.
final class KeychainMoveTests: XCTestCase {
    private let service = "lastide.move-test"

    override func setUp() { TestKeychain.deleteAll(service: service) }
    override func tearDown() { TestKeychain.deleteAll(service: service) }

    func testU3AnItemOutsideTheSharedGroupMovesIntoIt() throws {
        let shared = try KeychainGroup.shared()
        XCTAssertTrue(shared.hasSuffix("dev.lastide.app.shared"))
        let value = Data([1, 2, 3, 4])
        XCTAssertEqual(TestKeychain.add(service: service, account: "a.key", group: outsideGroup, value: value), errSecSuccess)
        let oldGroup = try XCTUnwrap(TestKeychain.group(service: service, account: "a.key"))
        XCTAssertEqual(oldGroup, outsideGroup, "the item sits outside the shared group before the move")
        let report = try KeychainMove.run(service: service, into: shared)
        XCTAssertEqual(report, KeychainMove.Report(moved: 1, duplicatesRemoved: 0))
        let moved = try XCTUnwrap(TestKeychain.read(service: service, account: "a.key", group: shared))
        XCTAssertEqual(moved.0, value)
        XCTAssertEqual(moved.1, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String, "the copy keeps its accessibility")
        XCTAssertNil(TestKeychain.read(service: service, account: "a.key", group: oldGroup))
        XCTAssertEqual(try KeychainMove.run(service: service, into: shared), KeychainMove.Report(), "a second run does nothing")
    }

    func testU3ARunThatFindsTwoCopiesLeavesOne() throws {
        let shared = try KeychainGroup.shared()
        let value = Data([9, 8, 7])
        XCTAssertEqual(TestKeychain.add(service: service, account: "b.token", group: outsideGroup, value: value), errSecSuccess)
        XCTAssertEqual(TestKeychain.add(service: service, account: "b.token", group: shared, value: value), errSecSuccess)
        let report = try KeychainMove.run(service: service, into: shared)
        XCTAssertEqual(report, KeychainMove.Report(moved: 0, duplicatesRemoved: 1))
        XCTAssertEqual(TestKeychain.read(service: service, account: "b.token", group: shared)?.0, value)
        XCTAssertNil(TestKeychain.read(service: service, account: "b.token", group: outsideGroup))
    }
}
