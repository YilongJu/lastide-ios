import LastideKit
import SwiftUI
import UIKit

/// The widget's view at its two sizes, for the screenshots `widgetSmall` and `widgetRectangular` (design section 6.7).
/// The app draws the same `WaitingCountView` as the widget, on made-up counts: three rules waiting, none waiting, and
/// no paired PC.
struct WidgetScreenshotView: View {
    let style: WaitingCountStyle

    private var samples: [WaitingSummary] {
        let twoMinutesAgo = currentTimeMs() - 120_000
        return [WaitingSummary(state: .waiting(count: 3, updatedAt: twoMinutesAgo)),
                WaitingSummary(state: .waiting(count: 0, updatedAt: twoMinutesAgo)),
                WaitingSummary(state: .noPairing)]
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                ForEach(Array(samples.enumerated()), id: \.offset) { _, summary in
                    WaitingCountView(summary: summary, style: style)
                        .padding(style == .small ? 16 : 10)
                        .frame(width: style == .small ? 170 : 300, height: style == .small ? 170 : 76)
                        .background(RoundedRectangle(cornerRadius: style == .small ? 22 : 14).fill(.fill.tertiary))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        }
        .background(Color(.systemGroupedBackground))
        .accessibilityIdentifier("screen.widget")
    }
}
