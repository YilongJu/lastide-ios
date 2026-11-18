import XCTest

/// One screenshot test per screen, each in light and dark, on demo data (plan Table 14).
///
/// Each run launches the app with `-LastideScreen <screen> -LastideColorScheme <scheme>`. The app then shows that screen
/// on its bundled demo fixtures and never touches the disk, the Keychain or the network. Each picture is kept in the
/// result bundle. When CI sets `TEST_RUNNER_LASTIDE_SCREENSHOT_DIR`, xcodebuild hands it to this process as
/// `LASTIDE_SCREENSHOT_DIR`, and each picture is also written there as `<screen>-<scheme>.png`.
@MainActor
final class ScreenshotTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    func testQueue() throws { try capture("queue", waitFor: identifier("screen.queue")) }
    func testRuleDetail() throws { try capture("draftDetail", waitFor: identifier("screen.draftDetail")) }
    func testLibrary() throws { try capture("library", waitFor: identifier("screen.library")) }
    func testLibraryRule() throws { try capture("ruleDetail", waitFor: identifier("screen.ruleDetail")) }
    func testLearning() throws { try capture("learning", waitFor: identifier("screen.learning")) }
    func testSettings() throws { try capture("settings", waitFor: identifier("screen.settings")) }
    func testPairingDisclosure() throws {
        try capture("pairingDisclosure", waitFor: NSPredicate(format: "label BEGINSWITH %@", "Rules you approve or edit here"))
    }
    func testPairingCheckCode() throws { try capture("pairingCode", waitFor: identifier("checkCode")) }

    private func identifier(_ id: String) -> NSPredicate { NSPredicate(format: "identifier == %@", id) }

    private func capture(_ screen: String, waitFor predicate: NSPredicate) throws {
        for scheme in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["-LastideScreen", screen, "-LastideColorScheme", scheme]
            app.launch()
            let element = app.descendants(matching: .any).matching(predicate).firstMatch
            XCTAssertTrue(element.waitForExistence(timeout: 30), "\(screen) in \(scheme) did not appear")
            // Let the navigation push and the charts finish drawing.
            Thread.sleep(forTimeInterval: 1.5)
            let png = XCUIScreen.main.screenshot().pngRepresentation
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "\(screen)-\(scheme)"
            attachment.lifetime = .keepAlways
            add(attachment)
            if let folder = ProcessInfo.processInfo.environment["LASTIDE_SCREENSHOT_DIR"] {
                let directory = URL(fileURLWithPath: folder, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try png.write(to: directory.appendingPathComponent("\(screen)-\(scheme).png"))
            }
            app.terminate()
        }
    }
}
