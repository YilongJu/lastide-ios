import Foundation
import LastideKit
import Observation

/// The bundled changelog, the What's New screen's sections and the sheet shown once after an update.
///
/// The app stores one value: the last build whose What's New it handled, under `LastideLastSeenBuild` in
/// `UserDefaults.standard`. A screenshot run and the hosted tests read and write nothing.
@MainActor
@Observable
final class WhatsNew {
    static let lastSeenKey = "LastideLastSeenBuild"

    /// The file as bundled, shown as is when it does not parse.
    let text: String
    /// The parsed file, or why it did not parse.
    let parsed: Result<Changelog, ChangelogError>
    /// The build the What's New screen marks as the one on this phone.
    let installedBuild: Int
    /// The entry the sheet shows once, or nil.
    var sheet: ChangelogEntry? = nil
    private let defaults: UserDefaults?

    init(text: String, installedBuild: Int, lastSeenBuild: Int?, defaults: UserDefaults?) {
        self.text = text
        self.installedBuild = installedBuild
        self.defaults = defaults
        do {
            parsed = .success(try Changelog.parse(text))
        } catch let error as ChangelogError {
            parsed = .failure(error)
        } catch {
            preconditionFailure("Changelog.parse threw \(error), which is no ChangelogError")
        }
        if case .success(let log) = parsed {
            sheet = log.whatsNew(installedBuild: installedBuild, lastSeenBuild: lastSeenBuild)
        }
        // With nothing to show, this build counts as seen at once. With a sheet, it counts once the sheet appears.
        if sheet == nil { markSeen() }
    }

    /// The sections newest first, or nil when the file did not parse.
    var entries: [ChangelogEntry]? {
        guard case .success(let log) = parsed else { return nil }
        return log.entries(installedBuild: installedBuild)
    }

    /// Records the installed build as seen, so the sheet does not show again for it.
    func markSeen() {
        guard let defaults else { return }
        let seen = defaults.object(forKey: Self.lastSeenKey) as? Int
        if installedBuild > (seen ?? 0) { defaults.set(installedBuild, forKey: Self.lastSeenKey) }
    }

    /// The text of `CHANGELOG.md` in the app bundle. A build without it is broken, so the app stops.
    static func bundledText(_ bundle: Bundle = .main) -> String {
        guard let url = bundle.url(forResource: "CHANGELOG", withExtension: "md") else {
            preconditionFailure("the app bundle lacks CHANGELOG.md")
        }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            preconditionFailure("CHANGELOG.md in the app bundle does not read as UTF-8: \(error)")
        }
    }

    /// The real app: the bundled file, this build's number and the stored last seen build.
    static func live(installedBuild: Int) -> WhatsNew {
        let defaults = UserDefaults.standard
        return WhatsNew(text: bundledText(), installedBuild: installedBuild,
                        lastSeenBuild: defaults.object(forKey: lastSeenKey) as? Int, defaults: defaults)
    }

    /// A run that shows no sheet and stores nothing: the hosted tests' host and every screenshot but the What's New ones.
    static func quiet(installedBuild: Int) -> WhatsNew {
        WhatsNew(text: bundledText(), installedBuild: installedBuild, lastSeenBuild: Int.max, defaults: nil)
    }

    /// A screenshot run. A simulator build is numbered 1, so the run plays the TestFlight build that the bundled file
    /// describes next: one above the newest listed build while Unreleased holds entries. `whatsNewSheet` shows the sheet
    /// of that build, and `whatsNewMalformed` reads a file that does not parse.
    static func screenshot(_ screen: ScreenshotScreen) -> WhatsNew {
        let text = screen == .whatsNewMalformed ? malformedSample : bundledText()
        let build: Int
        if let log = try? Changelog.parse(bundledText()), let latest = log.latestBuild {
            build = log.unreleased.isEmpty ? latest : latest + 1
        } else {
            build = 1
        }
        return WhatsNew(text: text, installedBuild: build,
                        lastSeenBuild: screen == .whatsNewSheet ? build - 1 : Int.max, defaults: nil)
    }

    /// A made-up file whose second heading does not parse.
    static let malformedSample = """
    # Changelog

    ## Build 3 (2026-11-23)

    - The Learning screen shows today's drafting runs.

    ## Build two

    - This heading has no build number.
    """
}
