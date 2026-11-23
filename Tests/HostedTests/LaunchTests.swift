import Foundation
@testable import Lastide
import LastideKit
import UIKit
import XCTest

/// Design Table 21, checks U4 and U9: the launch path of a phase 7 build.
@MainActor
final class LaunchTests: XCTestCase {
    override func setUp() async throws { TestKeychain.deleteAll(service: KeychainStore.service) }
    override func tearDown() async throws { TestKeychain.deleteAll(service: KeychainStore.service) }

    /// The phase 6 layout: `pairings.json` in Application Support, and the two Keychain items outside the shared group.
    private func phaseSixLayout(_ vector: PushVector) throws -> (appSupport: URL, oldPairings: URL) {
        let appSupport = try temporaryFolder("app-support")
        let oldPairings = appSupport.appendingPathComponent("pairings.json")
        try JSONEncoder().encode([vector.record]).write(to: oldPairings)
        XCTAssertEqual(TestKeychain.add(service: KeychainStore.service, account: SecretAccount.key(vector.id),
                                        group: outsideGroup, value: vector.phoneKey), errSecSuccess)
        XCTAssertEqual(TestKeychain.add(service: KeychainStore.service, account: SecretAccount.token(vector.id),
                                        group: outsideGroup, value: vector.token), errSecSuccess)
        return (appSupport, oldPairings)
    }

    private func environment(appSupport: URL, oldPairings: URL, group: GroupFiles?) -> LaunchEnvironment {
        LaunchEnvironment(files: { try FileStorage(directory: appSupport) }, oldPairingsURL: oldPairings,
                          group: { group }, keychainGroup: { try KeychainGroup.shared() },
                          secrets: { KeychainStore(accessGroup: $0) },
                          moveKeychain: { try KeychainMove.run(service: KeychainStore.service, into: $0) },
                          protectedDataAvailable: { true }, registerForPushes: {})
    }

    func testU4TheFirstLaunchMovesBothAndEveryItemSurvives() throws {
        let vector = try PushVector()
        let (appSupport, oldPairings) = try phaseSixLayout(vector)
        let group = GroupFiles(directory: try temporaryFolder("group"))
        let harness = try ModelHarness()
        let runtime = AppRuntime(model: harness.model, screenshot: nil,
                                 environment: environment(appSupport: appSupport, oldPairings: oldPairings, group: group))
        runtime.start()
        XCTAssertNil(harness.model.launchError)
        XCTAssertTrue(harness.model.isLoaded)
        XCTAssertEqual(harness.model.records, [vector.record])
        XCTAssertEqual(harness.model.selectedID, vector.id)
        XCTAssertTrue(harness.model.brokenIDs.isEmpty, "both Keychain items survived the move and the sweep")
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldPairings.path))
        XCTAssertEqual(harness.model.diagnostics.launchMoves, "moved 2 Keychain items, removed 0 duplicates, moved pairings.json")
        XCTAssertEqual(harness.model.diagnostics.sharedKeychainItems, 2)
        XCTAssertEqual(try group.loadRecords(), [vector.record])
        let shared = try KeychainGroup.shared()
        XCTAssertEqual(TestKeychain.read(service: KeychainStore.service, account: SecretAccount.key(vector.id),
                                         group: shared)?.0, vector.phoneKey)
        XCTAssertEqual(TestKeychain.read(service: KeychainStore.service, account: SecretAccount.token(vector.id),
                                         group: shared)?.0, vector.token)
        XCTAssertNil(TestKeychain.read(service: KeychainStore.service, account: SecretAccount.key(vector.id),
                                       group: outsideGroup))
    }

    func testU4ANilAppGroupContainerShowsTheStorageErrorAndDeletesNothing() throws {
        let vector = try PushVector()
        let (appSupport, oldPairings) = try phaseSixLayout(vector)
        let harness = try ModelHarness()
        var registered = false
        var launch = environment(appSupport: appSupport, oldPairings: oldPairings, group: nil)
        launch.registerForPushes = { registered = true }
        let runtime = AppRuntime(model: harness.model, screenshot: nil, environment: launch)
        runtime.start()
        XCTAssertEqual(harness.model.launchError, "Lastide cannot open its App Group storage.")
        XCTAssertFalse(harness.model.isLoaded)
        XCTAssertFalse(registered, "the app stops before it registers")
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldPairings.path), "pairings.json stays where it was")
        XCTAssertEqual(TestKeychain.read(service: KeychainStore.service, account: SecretAccount.key(vector.id),
                                         group: outsideGroup)?.0, vector.phoneKey)
        XCTAssertEqual(TestKeychain.read(service: KeychainStore.service, account: SecretAccount.token(vector.id),
                                         group: outsideGroup)?.0, vector.token)
    }

    /// U9: files that throw the file protection error leave the model unloaded, and a count update still lands in
    /// `counts/` from the App Group files and the Keychain store alone.
    func testU9ALockedLaunchLoadsNothingAndStillStoresACountUpdate() throws {
        let vector = try PushVector()
        let group = GroupFiles(directory: try temporaryFolder("group"))
        try group.saveRecords([vector.record])
        let secrets = MemorySecrets()
        try secrets.save(vector.phoneKey, account: SecretAccount.key(vector.id))
        try secrets.save(vector.token, account: SecretAccount.token(vector.id))
        let harness = try ModelHarness()
        let environment = LaunchEnvironment(
            files: { LockedFiles() }, oldPairingsURL: try temporaryFolder("none").appendingPathComponent("pairings.json"),
            group: { group }, keychainGroup: { "TESTTEAM01.dev.lastide.app.shared" }, secrets: { _ in secrets },
            moveKeychain: { _ in KeychainMove.Report() }, protectedDataAvailable: { true }, registerForPushes: {})
        let runtime = AppRuntime(model: harness.model, screenshot: nil, environment: environment)
        runtime.start()
        XCTAssertFalse(harness.model.isLoaded)
        XCTAssertNil(harness.model.launchError, "a locked phone is not a launch error")
        XCTAssertTrue(harness.model.records.isEmpty)
        XCTAssertNotNil(harness.model.diagnostics.lastError)

        let payload: [AnyHashable: Any] = ["lastide": ["v": 1, "e": try vector.e("countUpdate")]]
        XCTAssertEqual(runtime.handleBackgroundPush(payload), .newData)
        let count = try XCTUnwrap(try group.loadCount(vector.id))
        XCTAssertEqual(count.storeVersion, 44)
        XCTAssertEqual(count.queueCount, 0)
        XCTAssertEqual(harness.widgets.reloads, 1)
        XCTAssertEqual(harness.notices.badges, [0])
        XCTAssertEqual(runtime.handleBackgroundPush(payload), .noData, "the same store version changes nothing")
        XCTAssertEqual(runtime.handleBackgroundPush(["lastide": ["v": 1, "e": try vector.e("notice")]]), .failed,
                       "an alert notice is not a count update")
    }
}
