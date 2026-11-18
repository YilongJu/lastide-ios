import XCTest

/// Screenshot tests for every screen and state, each in light and dark (plan Table 14).
///
/// Each run launches the app with `-LastideScreen <screen> -LastideColorScheme <scheme>`. The app then shows that screen
/// on its bundled demo fixtures, or on a synthetic paired PC, and never touches the disk, the Keychain or the network.
/// Some captures then scroll, type or tap before the picture. The "-large" captures run at the accessibility text size
/// AX3. Each picture is kept in the result bundle. When CI sets `TEST_RUNNER_LASTIDE_SCREENSHOT_DIR`, xcodebuild hands
/// it to this process as `LASTIDE_SCREENSHOT_DIR`, and each picture is also written there as `<name>-<scheme>.png`.
@MainActor
final class ScreenshotTests: XCTestCase {
    /// The content size category of Dynamic Type's accessibility size 3.
    private static let accessibility3 = "UICTContentSizeCategoryAccessibilityXL"

    override func setUp() async throws {
        continueAfterFailure = false
    }

    // MARK: Review

    func testQueue() throws { try capture("queue", waitFor: identifier("screen.queue")) }
    func testQueueWaiting() throws { try capture("queueWaiting", waitFor: identifier("status")) }
    func testQueueEmpty() throws { try capture("queueEmpty", waitFor: identifier("queueEmpty")) }
    func testRuleDetail() throws { try capture("draftDetail", waitFor: approveButton) }
    func testRuleDetailEnd() throws {
        try capture("draftDetailEnd", screen: "draftDetail", waitFor: approveButton) { app in
            app.swipeUp()
            try self.expect(app, self.identifier("appearsWhileOnline"))
        }
    }
    func testRuleDetailEdited() throws {
        try capture("draftDetailEdited", screen: "draftDetail", waitFor: identifier("ruleText")) { app in
            try self.typeAtEnd(app, " Keep it short.")
            try self.expect(app, NSPredicate(format: "label == %@", "Save Edit"))
        }
    }

    // MARK: Library

    func testLibrary() throws { try capture("library", waitFor: identifier("screen.library")) }
    func testLibraryRule() throws { try capture("ruleDetail", waitFor: identifier("screen.ruleDetail")) }
    func testLibraryRuleEdited() throws {
        try capture("ruleDetailEdited", screen: "ruleDetail", waitFor: identifier("ruleText")) { app in
            try self.typeAtEnd(app, " Keep it short.")
            try self.expect(app, NSPredicate(format: "label == %@", "Save Edit"))
        }
    }

    // MARK: Learning

    func testLearning() throws { try capture("learning", waitFor: identifier("screen.learning")) }
    func testLearningEnd() throws {
        try capture("learningEnd", screen: "learning", waitFor: identifier("screen.learning")) { app in
            app.swipeUp()
            app.swipeUp()
        }
    }

    // MARK: Pair and Settings

    func testSettings() throws { try capture("settings", waitFor: identifier("screen.settings")) }
    func testSettingsPaired() throws { try capture("settingsPaired", waitFor: identifier("pairedPC")) }
    func testDiagnostics() throws {
        try capture("diagnostics", screen: "settingsPaired", waitFor: identifier("pairedPC")) { app in
            app.buttons["Diagnostics"].firstMatch.tap()
            try self.expect(app, self.identifier("screen.diagnostics"))
        }
    }
    func testPairingDisclosure() throws {
        try capture("pairingDisclosure", waitFor: NSPredicate(format: "label BEGINSWITH %@", "Rules you approve or edit here"))
    }
    func testPairingScan() throws { try capture("pairingScan", waitFor: identifier("pastedCode")) }
    func testPairingWaiting() throws { try capture("pairingWaiting", waitFor: identifier("pairingWaiting")) }
    func testPairingCheckCode() throws { try capture("pairingCode", waitFor: identifier("checkCode")) }
    func testPairingFailed() throws { try capture("pairingFailed", waitFor: identifier("pairingFailed")) }

    // MARK: Large text

    func testQueueLarge() throws { try capture("queue-large", screen: "queue", waitFor: identifier("screen.queue"), large: true) }
    func testRuleDetailLarge() throws {
        try capture("draftDetail-large", screen: "draftDetail", waitFor: approveButton, large: true)
    }
    func testLibraryLarge() throws {
        try capture("library-large", screen: "library", waitFor: identifier("screen.library"), large: true)
    }
    func testLibraryRuleLarge() throws {
        try capture("ruleDetail-large", screen: "ruleDetail", waitFor: identifier("screen.ruleDetail"), large: true)
    }
    func testLearningLarge() throws {
        try capture("learning-large", screen: "learning", waitFor: identifier("screen.learning"), large: true)
    }
    func testSettingsLarge() throws {
        try capture("settings-large", screen: "settings", waitFor: identifier("screen.settings"), large: true)
    }

    // MARK: Helpers

    private func identifier(_ id: String) -> NSPredicate { NSPredicate(format: "identifier == %@", id) }

    /// The Approve button of the draft's action bar. The bar sits inside the screen's identifier, so it is found by label.
    private var approveButton: NSPredicate {
        NSPredicate(format: "elementType == %d AND label == %@", XCUIElement.ElementType.button.rawValue, "Approve")
    }

    private func expect(_ app: XCUIApplication, _ predicate: NSPredicate) throws {
        let element = app.descendants(matching: .any).matching(predicate).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 15), "no element matches \(predicate)")
    }

    /// Taps the rule text near its end, so the caret lands after the last word, and types.
    private func typeAtEnd(_ app: XCUIApplication, _ text: String) throws {
        let field = app.descendants(matching: .any).matching(identifier("ruleText")).firstMatch
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.8)).tap()
        field.typeText(text)
    }

    /// Launches the app on `screen` (the picture's name when nil) in both schemes, waits for `predicate`, runs `prepare`,
    /// and writes `<name>-<scheme>.png`.
    private func capture(_ name: String, screen: String? = nil, waitFor predicate: NSPredicate, large: Bool = false,
                         prepare: ((XCUIApplication) throws -> Void)? = nil) throws {
        for scheme in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["-LastideScreen", screen ?? name, "-LastideColorScheme", scheme]
            if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", Self.accessibility3] }
            app.launch()
            let element = app.descendants(matching: .any).matching(predicate).firstMatch
            XCTAssertTrue(element.waitForExistence(timeout: 30), "\(name) in \(scheme) did not appear")
            try prepare?(app)
            // Let the navigation push, the scroll and the charts finish drawing.
            Thread.sleep(forTimeInterval: 1.5)
            let png = XCUIScreen.main.screenshot().pngRepresentation
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "\(name)-\(scheme)"
            attachment.lifetime = .keepAlways
            add(attachment)
            if let folder = ProcessInfo.processInfo.environment["LASTIDE_SCREENSHOT_DIR"] {
                let directory = URL(fileURLWithPath: folder, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try png.write(to: directory.appendingPathComponent("\(name)-\(scheme).png"))
            }
            app.terminate()
        }
    }
}
