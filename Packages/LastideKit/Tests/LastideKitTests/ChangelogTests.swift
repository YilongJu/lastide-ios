import Foundation
@testable import LastideKit
import XCTest

final class ChangelogTests: XCTestCase {
    static let sample = """
    # Changelog

    What changed in each build, newest first.

    ## Unreleased

    - Settings has a What's New row.
    - A long entry that
      wraps onto a second line.

    ## Build 8 (2026-11-24)

    - Every number opens its cases.

    ## Build 7 (2026-11-24)

    - Fixed a crash.
    - Fixed another crash.
    """

    func testParsesUnreleasedAndBuildsNewestFirst() throws {
        let log = try Changelog.parse(Self.sample)
        XCTAssertEqual(log.unreleased, ["Settings has a What's New row.", "A long entry that wraps onto a second line."])
        XCTAssertEqual(log.builds.map(\.build), [8, 7])
        XCTAssertEqual(log.builds.map(\.date), ["2026-11-24", "2026-11-24"])
        XCTAssertEqual(log.builds[1].items, ["Fixed a crash.", "Fixed another crash."])
        XCTAssertEqual(log.latestBuild, 8)
    }

    func testUnreleasedBelongsToAnInstalledBuildNewerThanEveryListedBuild() throws {
        let log = try Changelog.parse(Self.sample)
        // A TestFlight build 9 carries the file from before the workflow stamps it: its Unreleased entries are build 9's.
        let nine = log.entries(installedBuild: 9)
        XCTAssertEqual(nine.map(\.title), ["Build 9", "Build 8", "Build 7"])
        XCTAssertEqual(nine.map(\.isInstalled), [true, false, false])
        XCTAssertNil(nine[0].date)
        XCTAssertEqual(nine[0].items.count, 2)
        // A build the file lists already is marked where it stands, and Unreleased stays unreleased.
        let eight = log.entries(installedBuild: 8)
        XCTAssertEqual(eight.map(\.title), ["Unreleased", "Build 8", "Build 7"])
        XCTAssertEqual(eight.map(\.isInstalled), [false, true, false])
        // A development build numbered 1 marks no entry.
        XCTAssertEqual(log.entries(installedBuild: 1).filter(\.isInstalled).count, 0)
        XCTAssertEqual(log.entries(installedBuild: 1).first?.title, "Unreleased")
    }

    func testAnEmptyUnreleasedSectionShowsNoEntry() throws {
        let log = try Changelog.parse("## Unreleased\n\n## Build 3 (2026-11-23)\n\n- One.\n")
        XCTAssertEqual(log.unreleased, [])
        XCTAssertEqual(log.entries(installedBuild: 4).map(\.title), ["Build 3"])
        XCTAssertNil(log.installedEntry(installedBuild: 4))
    }

    func testWhatsNewShowsOnceForANewerBuild() throws {
        let log = try Changelog.parse(Self.sample)
        XCTAssertEqual(log.whatsNew(installedBuild: 9, lastSeenBuild: 8)?.title, "Build 9")
        XCTAssertEqual(log.whatsNew(installedBuild: 9, lastSeenBuild: nil)?.title, "Build 9", "a phone with no stored build sees it")
        XCTAssertEqual(log.whatsNew(installedBuild: 8, lastSeenBuild: 7)?.title, "Build 8")
        XCTAssertNil(log.whatsNew(installedBuild: 9, lastSeenBuild: 9), "the same build shows nothing again")
        XCTAssertNil(log.whatsNew(installedBuild: 8, lastSeenBuild: 9), "an older build shows nothing")
        XCTAssertNil(log.whatsNew(installedBuild: 1, lastSeenBuild: nil), "a build the file does not describe shows nothing")
    }

    func testRefusesAMalformedFileWithItsLine() {
        let cases: [(String, Int, String)] = [
            ("## Build 8 (2026-11-24)\n- One.\n## Build 8 (2026-11-24)\n- Two.\n", 3, "newer"),
            ("## Build 7 (2026-11-24)\n- One.\n## Build 8 (2026-11-24)\n- Two.\n", 3, "newer"),
            ("## Build 8 (24 Nov)\n- One.\n", 1, "date"),
            ("## Build 0 (2026-11-24)\n- One.\n", 1, "heading"),
            ("## Build 8 (2026-13-24)\n- One.\n", 1, "date"),
            ("## Build 8 (2026-11-24)\n", 1, "no entry"),
            ("## Build 8 (2026-11-24)\n- One.\n## Unreleased\n- Two.\n", 3, "first"),
            ("## Unreleased\n- One.\n## Unreleased\n- Two.\n", 3, "first"),
            ("## Build 8 (2026-11-24)\nloose words\n", 2, "line"),
            ("## Build 8 (2026-11-24)\n  wraps with no entry\n", 2, "line"),
            ("## Build 8 (2026-11-24)\n-\n", 2, "empty"),
            ("## Release notes\n- One.\n", 1, "heading"),
            ("# Changelog\n", 1, "no section"),
            ("", 1, "no section"),
        ]
        for (text, line, reason) in cases {
            XCTAssertThrowsError(try Changelog.parse(text), "\(text.debugDescription) parsed") { error in
                guard let error = error as? ChangelogError else { return XCTFail("\(error) is no ChangelogError") }
                XCTAssertEqual(error.line, line, "\(text.debugDescription): \(error)")
                XCTAssertTrue(error.reason.contains(reason), "\(text.debugDescription): \(error.reason)")
                XCTAssertTrue(error.description.hasPrefix("Line \(line): "), error.description)
            }
        }
    }

    func testReadsWindowsLineEndings() throws {
        let log = try Changelog.parse(Self.sample.replacingOccurrences(of: "\n", with: "\r\n"))
        XCTAssertEqual(log.builds.map(\.build), [8, 7])
        XCTAssertEqual(log.unreleased.last, "A long entry that wraps onto a second line.")
    }

    /// The file the app bundles parses, lists builds 2 to the newest without a gap, and keeps 1 to 8 entries per build.
    func testTheRepositoryChangelogParses() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("CHANGELOG.md"), encoding: .utf8)
        let log = try Changelog.parse(text)
        let latest = try XCTUnwrap(log.latestBuild)
        XCTAssertEqual(log.builds.map(\.build), Array((2...latest).reversed()), "a build is missing from CHANGELOG.md")
        for section in log.builds {
            XCTAssertTrue((1...8).contains(section.items.count), "build \(section.build) has \(section.items.count) entries")
        }
    }
}
