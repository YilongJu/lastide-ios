import XCTest

/// The sheet that shows once after an update (`-LastideScreen whatsNewSheet`): Done closes it, and a run that plays no
/// update shows no sheet.
@MainActor
final class WhatsNewSheetTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    func testDoneClosesTheSheet() throws {
        let app = launch("whatsNewSheet")
        defer { app.terminate() }
        let sheet = app.descendants(matching: .any).matching(identifier: "whatsNewSheet").firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 30), "the What's New sheet did not appear")
        let title = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "What's new in build "))
        XCTAssertTrue(title.firstMatch.exists, "the sheet does not name its build")
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10), "Done did not close the sheet")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "screen.queue").firstMatch.exists,
                      "the Review tab is not under the sheet")
    }

    func testARunWithoutAnUpdateShowsNoSheet() throws {
        let app = launch("queue")
        defer { app.terminate() }
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "screen.queue").firstMatch.waitForExistence(timeout: 30))
        // Give a sheet the time it would take to slide in.
        Thread.sleep(forTimeInterval: 2)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "whatsNewSheet").firstMatch.exists,
                       "a run without an update showed the What's New sheet")
    }

    private func launch(_ screen: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-LastideScreen", screen, "-LastideColorScheme", "light"]
        // A launch while the last copy still closes fails, so each launch waits until no copy runs.
        if app.state != .notRunning && app.state != .unknown { app.terminate() }
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 20), "the app did not stop within 20 s")
        app.launch()
        return app
    }
}
