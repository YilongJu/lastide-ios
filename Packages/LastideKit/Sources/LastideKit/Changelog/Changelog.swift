import Foundation

/// The app's changelog, `CHANGELOG.md` at the repository root, which the app bundles and shows in Settings, What's New.
///
/// The format, line by line:
///
/// - An optional `# ` title and any lines of introduction before the first section.
/// - `## Unreleased`, at most once and only as the first section: the entries of the next TestFlight build.
/// - `## Build N (YYYY-MM-DD)`: one section per TestFlight build, `N` its build number, newest first.
/// - `- ` starts an entry. A line indented by two spaces continues the entry above it. Blank lines are ignored.
///
/// Any other line refuses the file, so the app shows the raw text instead of a wrong list.
public struct Changelog: Hashable, Sendable {
    /// One build's section.
    public struct Build: Hashable, Sendable {
        public let build: Int
        /// The date of the TestFlight upload, as written: `YYYY-MM-DD`.
        public let date: String
        public let items: [String]
    }

    /// The entries of the next TestFlight build. Empty when the file has no Unreleased section or it holds no entry.
    public let unreleased: [String]
    /// The builds, newest first.
    public let builds: [Build]

    /// The newest build the file lists, or nil when it lists none.
    public var latestBuild: Int? { builds.first?.build }

    public static func parse(_ text: String) throws -> Changelog {
        var unreleased: [String]?
        var builds: [Build] = []
        // The section that collects entries: nil before the first section.
        var current: (heading: Int, build: Int?, date: String, items: [String])?
        var sawSection = false

        func close() throws {
            guard let section = current else { return }
            if let build = section.build {
                guard !section.items.isEmpty else {
                    throw ChangelogError(line: section.heading, reason: "Build \(build) has no entry")
                }
                builds.append(Build(build: build, date: section.date, items: section.items))
            } else {
                unreleased = section.items
            }
            current = nil
        }

        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        for (index, raw) in lines.enumerated() {
            let number = index + 1
            let line = String(raw)
            if line.hasPrefix("## ") {
                try close()
                let heading = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                if heading == "Unreleased" {
                    guard !sawSection else {
                        throw ChangelogError(line: number, reason: "Unreleased must be the first section, and only once")
                    }
                    current = (number, nil, "", [])
                } else {
                    let (build, date) = try parseBuildHeading(heading, line: number)
                    if let previous = builds.last?.build, build >= previous {
                        throw ChangelogError(line: number, reason: "Build \(build) must be older than build \(previous) above it; list newer builds first")
                    }
                    current = (number, build, date, [])
                }
                sawSection = true
                continue
            }
            guard current != nil else {
                // The title and the introduction.
                continue
            }
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if line.hasPrefix("- ") || line == "-" {
                let item = line.dropFirst(1).trimmingCharacters(in: .whitespaces)
                guard !item.isEmpty else { throw ChangelogError(line: number, reason: "an entry is empty") }
                current!.items.append(item)
            } else if line.hasPrefix("  "), !current!.items.isEmpty {
                let more = line.trimmingCharacters(in: .whitespaces)
                current!.items[current!.items.count - 1] += " " + more
            } else {
                throw ChangelogError(line: number, reason: "this line is no heading, no entry and no continued entry")
            }
        }
        try close()
        guard sawSection else {
            throw ChangelogError(line: 1, reason: "the file holds no section; a section starts with \"## Unreleased\" or \"## Build N (YYYY-MM-DD)\"")
        }
        return Changelog(unreleased: unreleased ?? [], builds: builds)
    }

    private static func parseBuildHeading(_ heading: String, line: Int) throws -> (Int, String) {
        let bad = ChangelogError(line: line, reason: "a heading reads \"## Unreleased\" or \"## Build N (YYYY-MM-DD)\"")
        guard heading.hasPrefix("Build "), heading.hasSuffix(")") else { throw bad }
        let rest = heading.dropFirst("Build ".count).dropLast()
        let parts = rest.split(separator: " (", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let build = Int(parts[0]), build >= 1, String(build) == parts[0] else { throw bad }
        let date = String(parts[1])
        guard isDate(date) else { throw ChangelogError(line: line, reason: "the date \(date) is no YYYY-MM-DD date") }
        return (build, date)
    }

    private static func isDate(_ text: String) -> Bool {
        let fields = text.split(separator: "-", omittingEmptySubsequences: false)
        guard fields.count == 3, fields[0].count == 4, fields[1].count == 2, fields[2].count == 2,
              fields.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let year = Int(fields[0]), let month = Int(fields[1]), let day = Int(fields[2])
        else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: components) else { return false }
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        return back.year == year && back.month == month && back.day == day
    }

    // MARK: What the app shows

    /// The sections as the What's New screen lists them, newest first, with the installed build marked.
    ///
    /// A TestFlight build carries the file as it stood at its commit, before the workflow turns Unreleased into that
    /// build's section. So Unreleased entries are the installed build's own when the installed build is newer than every
    /// build the file lists. Otherwise, as in a development build numbered 1, they stay "Unreleased".
    public func entries(installedBuild: Int) -> [ChangelogEntry] {
        var entries: [ChangelogEntry] = []
        if !unreleased.isEmpty {
            if installedBuild > (latestBuild ?? 0) {
                entries.append(ChangelogEntry(build: installedBuild, date: nil, items: unreleased, isInstalled: true))
            } else {
                entries.append(ChangelogEntry(build: nil, date: nil, items: unreleased, isInstalled: false))
            }
        }
        for section in builds {
            entries.append(ChangelogEntry(build: section.build, date: section.date, items: section.items,
                                          isInstalled: section.build == installedBuild))
        }
        return entries
    }

    /// The installed build's entry, or nil when the file does not describe it.
    public func installedEntry(installedBuild: Int) -> ChangelogEntry? {
        entries(installedBuild: installedBuild).first(where: \.isInstalled)
    }

    /// The entry to show once after an update: the installed build's, when it is newer than the last build the app
    /// showed. A phone that stored no build yet counts as having seen none.
    public func whatsNew(installedBuild: Int, lastSeenBuild: Int?) -> ChangelogEntry? {
        guard installedBuild > (lastSeenBuild ?? 0) else { return nil }
        return installedEntry(installedBuild: installedBuild)
    }
}

/// One section of the What's New screen.
public struct ChangelogEntry: Hashable, Sendable, Identifiable {
    /// The build number, or nil for entries that no build carries yet.
    public let build: Int?
    /// The upload date as `YYYY-MM-DD`, or nil when the file gives none.
    public let date: String?
    public let items: [String]
    /// True for the build on this phone.
    public let isInstalled: Bool

    /// "Build 9", or "Unreleased".
    public var title: String { build.map { "Build \($0)" } ?? "Unreleased" }
    public var id: String { title }
}

/// Why `Changelog.parse` refused a file.
public struct ChangelogError: Error, Hashable, Sendable, CustomStringConvertible {
    /// The 1-based line number.
    public let line: Int
    public let reason: String

    public var description: String { "Line \(line): \(reason)" }
}
