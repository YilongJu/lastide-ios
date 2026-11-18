import LastideKit
import SwiftUI
import UIKit

extension Color {
    /// The text colour of a status badge. System orange on a white card measures about 2.2:1, so the badge text uses a
    /// deep orange in light mode and a pale orange in dark mode. Both measure over 5:1 on the badge's tinted fill.
    static let statusText = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 1.0, green: 0.70, blue: 0.36, alpha: 1)
            : UIColor(red: 0.66, green: 0.26, blue: 0.0, alpha: 1)
    })
}

/// A small tinted capsule with an icon and a short sentence, such as "Approve this one on your PC".
struct StatusBadge: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.footnote.weight(.medium))
            .foregroundStyle(Color.statusText)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.orange.opacity(0.15)))
            .accessibilityIdentifier("status")
    }
}

extension ItemStatus {
    /// The SF Symbol of the status badge.
    var symbol: String {
        switch self {
        case .ready: return "checkmark.circle"
        case .desktopOnly: return "desktopcomputer"
        case .notSent: return "arrow.up.circle"
        case .waitingForPC: return "clock"
        case .refused: return "exclamationmark.circle"
        }
    }
}

/// The capsule of a rule that the person turned off.
struct OffBadge: View {
    var body: some View {
        Label("Off", systemImage: "pause.circle")
            .font(.footnote.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.secondary.opacity(0.18)))
    }
}

/// One row that says the screen shows sample data, with a button that opens the Settings tab.
struct DemoBanner: View {
    let text: String
    let onPair: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                label
                Spacer(minLength: 8)
                button
            }
            VStack(alignment: .leading, spacing: 8) {
                label
                button
            }
        }
        .accessibilityIdentifier("demoBanner")
    }

    private var label: some View {
        Label(text, systemImage: "sparkles")
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    private var button: some View {
        Button("Pair a PC", action: onPair)
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
    }
}
