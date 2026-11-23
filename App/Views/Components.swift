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

/// A paired PC's connection, as its badge on the Settings screen shows it.
struct PCStatusBadge: View {
    let online: Bool
    /// "last seen 2 min ago" or "not seen yet". Unused while the PC is online.
    let lastSeen: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: online ? "circle.fill" : "circle")
                .imageScale(.small)
                .font(.caption2)
            Text(online ? "Online" : lastSeen.prefix(1).uppercased() + lastSeen.dropFirst())
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(online ? Color.onlineText : Color.offlineText)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(online ? Color.onlineFill : Color.offlineFill))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(online ? "Online" : "Offline, \(lastSeen)")
        .accessibilityIdentifier("pcStatus")
    }
}

extension Color {
    /// Deep green on a pale green fill in light mode, pale green on a dark green fill in dark mode. Both measure over 5:1.
    static let onlineText = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.55, green: 0.92, blue: 0.62, alpha: 1)
            : UIColor(red: 0.0, green: 0.42, blue: 0.16, alpha: 1)
    })
    static let onlineFill = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.19, green: 0.82, blue: 0.35, alpha: 0.18)
            : UIColor(red: 0.20, green: 0.78, blue: 0.35, alpha: 0.15)
    })
    /// Dark grey on a light grey fill in light mode, light grey on a mid grey fill in dark mode. Both measure over 6:1.
    static let offlineText = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.78, green: 0.78, blue: 0.80, alpha: 1)
            : UIColor(red: 0.28, green: 0.28, blue: 0.30, alpha: 1)
    })
    static let offlineFill = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.23, green: 0.23, blue: 0.24, alpha: 1)
            : UIColor(red: 0.90, green: 0.90, blue: 0.92, alpha: 1)
    })
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
/// At the accessibility text sizes the button moves under the sentence.
struct DemoBanner: View {
    let text: String
    let onPair: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    label
                    button
                }
            } else {
                HStack(spacing: 12) {
                    label
                    Spacer(minLength: 8)
                    button
                }
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
