import SwiftUI
import WidgetKit

/// The widget extension (design section 6.7).
///
/// Round 3a of the phase 7 design ships this scaffold with fixed text. Round 3b reads the waiting count from the App
/// Group. The kind stays the same, so a widget that the person placed keeps its place.
@main
struct LastideWidgetBundle: WidgetBundle {
    var body: some Widget { WaitingCountWidget() }
}

struct WaitingCountWidget: Widget {
    static let kind = "LastideWaitingCount"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: FixedProvider()) { _ in
            Text("Lastide")
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Rules waiting")
        .description("How many rules wait for your review.")
        .supportedFamilies([.systemSmall, .accessoryRectangular])
    }
}

struct FixedEntry: TimelineEntry {
    let date: Date
}

struct FixedProvider: TimelineProvider {
    func placeholder(in context: Context) -> FixedEntry { FixedEntry(date: Date()) }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (FixedEntry) -> Void) {
        completion(FixedEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<FixedEntry>) -> Void) {
        completion(Timeline(entries: [FixedEntry(date: Date())], policy: .never))
    }
}
