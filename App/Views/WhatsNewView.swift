import LastideKit
import SwiftUI

/// Settings, What's New: the bundled changelog by build, newest first, with the build on this phone marked.
/// A file that does not parse shows as raw text with the reason, so the list never shows wrong sections.
struct WhatsNewView: View {
    let whatsNew: WhatsNew

    var body: some View {
        List {
            switch whatsNew.parsed {
            case .success:
                ForEach(whatsNew.entries ?? []) { entry in
                    Section {
                        ForEach(Array(entry.items.enumerated()), id: \.offset) { _, item in
                            ChangeRow(text: item)
                        }
                    } header: {
                        EntryHeader(entry: entry)
                    }
                }
            case .failure(let error):
                Section {
                    Text(whatsNew.text)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .accessibilityIdentifier("changelogRaw")
                } header: {
                    Text("The list could not be read")
                        .textCase(nil)
                } footer: {
                    Text("This build's changelog shows as written. \(error.description).")
                        .accessibilityIdentifier("changelogError")
                }
            }
        }
        .navigationTitle("What's New")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("screen.whatsNew")
    }
}

/// "Build 9" with its date, and the badge "On this iPhone" for the installed build.
private struct EntryHeader: View {
    let entry: ChangelogEntry
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
        layout {
            Text(entry.title)
                .font(.headline)
                .foregroundStyle(.primary)
            if let date = entry.date {
                Text(WhatsNewText.date(date))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if entry.isInstalled {
                InstalledBadge()
            }
        }
        .textCase(nil)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier(entry.isInstalled ? "installedEntry" : "entryHeader")
    }
}

/// The capsule that marks the build on this phone.
private struct InstalledBadge: View {
    var body: some View {
        Label(WhatsNewText.installed, systemImage: "iphone")
            .font(.footnote.weight(.medium))
            .foregroundStyle(Color.onlineText)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.onlineFill))
    }
}

/// One change, with a bullet that wraps with its text.
private struct ChangeRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•").foregroundStyle(.secondary).accessibilityHidden(true)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("change")
    }
}

/// The sheet shown once after an update: the installed build's changes, with Done.
struct WhatsNewSheet: View {
    let entry: ChangelogEntry
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(entry.items.enumerated()), id: \.offset) { _, item in
                        ChangeRow(text: item)
                    }
                } footer: {
                    Text("Every build's changes are in Settings, What's New.")
                }
            }
            .navigationTitle(WhatsNewText.sheetTitle(entry))
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("whatsNewSheet")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// The words of the What's New screens.
enum WhatsNewText {
    static let installed = "On this iPhone"

    /// "What's new in build 9", or "What's new" for entries no build carries.
    static func sheetTitle(_ entry: ChangelogEntry) -> String {
        entry.build.map { "What's new in build \($0)" } ?? "What's new"
    }

    /// "2026-11-24" as "Nov 24, 2026". The file's dates are calendar days, so the format reads them in UTC.
    static func date(_ text: String) -> String {
        let utc = TimeZone(identifier: "UTC")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let fields = text.split(separator: "-").compactMap { Int($0) }
        // Changelog.parse accepts only real YYYY-MM-DD dates, so a date here always reads.
        guard fields.count == 3,
              let date = calendar.date(from: DateComponents(year: fields[0], month: fields[1], day: fields[2]))
        else { preconditionFailure("the parsed changelog holds the date \(text)") }
        var shown = Date.FormatStyle(date: .abbreviated, time: .omitted)
        shown.timeZone = utc
        return date.formatted(shown)
    }
}
