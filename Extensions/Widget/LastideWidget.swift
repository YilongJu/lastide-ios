import LastideKit
import SwiftUI
import WidgetKit

/// The widget extension (design section 6.7): the count of rules that wait for review on every paired PC.
///
/// The timeline policy is `.never`. The widget reloads on a widget push, on the app's reload call, and when iOS chooses.
/// The kind stays the same as the scaffold's, so a widget that the person placed keeps its place.
@main
struct LastideWidgetBundle: WidgetBundle {
    var body: some Widget { WaitingCountWidget() }
}

struct WaitingCountWidget: Widget {
    static let kind = "LastideWaitingCount"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: WaitingProvider()) { entry in
            WaitingEntryView(entry: entry)
        }
        .configurationDisplayName("Rules waiting")
        .description("How many rules wait for your review.")
        .supportedFamilies([.systemSmall, .accessoryRectangular])
        .pushHandler(WaitingPushHandler.self)
    }
}

struct WaitingEntry: TimelineEntry {
    let date: Date
    let summary: WaitingSummary
}

struct WaitingEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WaitingEntry

    var body: some View {
        WaitingCountView(summary: entry.summary, style: family == .accessoryRectangular ? .rectangular : .small)
            .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct WaitingProvider: TimelineProvider {
    func placeholder(in context: Context) -> WaitingEntry {
        WaitingEntry(date: Date(), summary: WaitingSummary(state: .waiting(count: 1, updatedAt: 0)))
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (WaitingEntry) -> Void) {
        completion(Self.current())
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<WaitingEntry>) -> Void) {
        completion(Timeline(entries: [Self.current()], policy: .never))
    }

    /// The newest counts in the App Group. A file that does not open shows the app's name.
    static func current() -> WaitingEntry {
        let summary: WaitingSummary
        do {
            summary = WaitingSummary.from(try GroupFiles.shared().waitingCounts())
        } catch {
            summary = WaitingSummary(state: .unreadable)
        }
        return WaitingEntry(date: Date(), summary: summary)
    }
}

/// Writes the widget push token to `widget-push.json`, which the app sends to the relay (design section 6.3).
struct WaitingPushHandler: WidgetPushHandler {
    func pushTokenDidChange(_ pushInfo: WidgetPushInfo, widgets: [WidgetInfo]) {
        let state = WidgetPushState(token: widgets.isEmpty ? nil : pushInfo.token.lowercaseHex, widgets: widgets.count,
                                    at: Int((Date().timeIntervalSince1970 * 1_000).rounded(.down)))
        // A handler has no channel for an error. A lost write costs nothing lasting, because the app also reads
        // `WidgetCenter.shared.currentPushInfo` after each welcome.
        try? GroupFiles.shared().saveWidgetPush(state)
    }
}
