import LastideKit
import SwiftUI

/// What the widget shows: the waiting count over all paired PCs and when it last changed (design section 6.7).
struct WaitingSummary: Equatable, Sendable {
    enum State: Equatable, Sendable {
        /// The sum of the newest counts, and the newest update time in ms.
        case waiting(count: Int, updatedAt: Int)
        /// No paired PC has a count yet.
        case noPairing
        /// The App Group files did not open, as before the first unlock after a restart.
        case unreadable
    }

    let state: State

    /// The summary of the newest count of each pairing.
    static func from(_ counts: [WaitingCount]) -> WaitingSummary {
        guard let newest = counts.map(\.at).max() else { return WaitingSummary(state: .noPairing) }
        return WaitingSummary(state: .waiting(count: WaitingCount.badge(counts), updatedAt: newest))
    }
}

/// The two widget families the widget offers.
enum WaitingCountStyle: Sendable {
    case small, rectangular
}

/// The waiting count, which the app's screenshots and the widget both draw. The count carries `.privacySensitive()`,
/// so the lock screen hides it while the phone is locked.
struct WaitingCountView: View {
    let summary: WaitingSummary
    let style: WaitingCountStyle

    var body: some View {
        VStack(alignment: .leading, spacing: style == .small ? 4 : 2) {
            switch summary.state {
            case .waiting(let count, let updatedAt):
                if style == .small {
                    Text("\(count)")
                        .font(.system(size: 44, weight: .semibold, design: .rounded))
                        .privacySensitive()
                }
                Text(PushText.widgetLine(count))
                    .font(style == .small ? .subheadline : .headline)
                    .privacySensitive()
                Text(PushText.widgetUpdated(Self.time(updatedAt)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            case .noPairing:
                Text(PushText.widgetPairPrompt)
                    .font(style == .small ? .subheadline : .headline)
            case .unreadable:
                Text(PushText.appName)
                    .font(.headline)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: style == .small ? .bottomLeading : .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("widget.waitingCount")
    }

    /// A protocol time as a short clock time, for example "14:05".
    static func time(_ ms: Int) -> String {
        Date(timeIntervalSince1970: Double(ms) / 1_000).formatted(date: .omitted, time: .shortened)
    }
}
