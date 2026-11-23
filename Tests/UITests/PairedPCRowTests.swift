import XCTest

/// The rows of the "Paired PCs" section on the Settings screen of two synthetic PCs (`-LastideScreen settingsPaired`):
/// WORKSTATION-A, shown and online, and STUDIO-LAPTOP, offline and last seen 3 hours ago.
///
/// Each PC has one row. The row holds the PC name, a status badge with a spoken label, and its own Revoke button.
/// The row does not repeat "Paired with", because the section title says it. The test runs at the default text size and
/// at the accessibility text size AX3.
@MainActor
final class PairedPCRowTests: XCTestCase {
    private static let accessibility3 = "UICTContentSizeCategoryAccessibilityXL"

    override func setUp() async throws {
        // Report every broken check of a run, so one run shows the whole state of the rows.
        continueAfterFailure = true
    }

    func testEachRowHoldsItsBadgeAndRevoke() throws { try checkRows(large: false) }
    func testEachRowHoldsItsBadgeAndRevokeAtLargeText() throws { try checkRows(large: true) }

    private func checkRows(large: Bool) throws {
        let app = XCUIApplication()
        app.launchArguments = ["-LastideScreen", "settingsPaired", "-LastideColorScheme", "light"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", Self.accessibility3] }
        app.launch()
        defer { app.terminate() }

        let rowQuery = app.descendants(matching: .any).matching(identifier: "pairedPC")
        XCTAssertTrue(rowQuery.firstMatch.waitForExistence(timeout: 30), "no paired PC row appeared")

        let pairedWith = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Paired with"))
        XCTAssertEqual(pairedWith.count, 0, "a row still says \"Paired with\"")

        XCTAssertEqual(rowQuery.count, 2, "the section should show one row per PC")
        let expected: [(name: String, status: NSPredicate)] = [
            ("WORKSTATION-A", NSPredicate(format: "label == %@", "Online")),
            ("STUDIO-LAPTOP", NSPredicate(format: "label == %@", "Offline, last seen 3 hours ago")),
        ]
        for (name, statusLabel) in expected {
            let row = rowQuery.containing(NSPredicate(format: "label == %@", name)).firstMatch
            XCTAssertTrue(row.exists, "no row holds the name \(name)")
            guard row.exists else { continue }

            let badge = row.descendants(matching: .any).matching(identifier: "pcStatus").firstMatch
            XCTAssertTrue(badge.exists, "the row of \(name) has no status badge")
            if badge.exists {
                XCTAssertTrue(statusLabel.evaluate(with: badge), "the badge of \(name) reads \"\(badge.label)\"")
            }

            let revoke = row.buttons.matching(identifier: "revokePC").firstMatch
            XCTAssertTrue(revoke.exists, "the row of \(name) has no Revoke button")
            if revoke.exists {
                XCTAssertEqual(revoke.label, "Revoke \(name)")
                XCTAssertTrue(row.frame.contains(revoke.frame),
                              "Revoke \(revoke.frame) lies outside the row of \(name) \(row.frame)")
            }
        }

        // Every Revoke on the screen sits in a PC row: none stands alone below a PC.
        let revokes = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Revoke"))
        XCTAssertEqual(revokes.count, 2, "the screen should show one Revoke per PC")
        for index in 0..<revokes.count {
            let frame = revokes.element(boundBy: index).frame
            let inside = (0..<rowQuery.count).contains { rowQuery.element(boundBy: $0).frame.contains(frame) }
            XCTAssertTrue(inside, "a Revoke button at \(frame) lies in no PC row")
        }

        // The Revoke button still asks first.
        let firstRevoke = rowQuery.containing(NSPredicate(format: "label == %@", "STUDIO-LAPTOP")).firstMatch
            .buttons.matching(identifier: "revokePC").firstMatch
        if firstRevoke.exists {
            firstRevoke.tap()
            let question = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@", "Revoke STUDIO-LAPTOP?")).firstMatch
            XCTAssertTrue(question.waitForExistence(timeout: 10), "Revoke did not ask before revoking")
        }
    }
}
