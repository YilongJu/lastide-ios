import Charts
import LastideKit
import SwiftUI

/// The Learning dashboard: the four numbers and the two weekly charts (plan section 4.3, protocol Table 23).
struct LearningView: View {
    @Bindable var model: AppModel
    /// Opens the Settings tab from the demo banner.
    let onPair: () -> Void

    var body: some View {
        NavigationStack {
            List {
                if model.isDemo {
                    Section { DemoBanner(text: AppText.sampleNumbers, onPair: onPair) }
                }
                if let counts = model.store.counts {
                    let current = counts.weeks.last?.weekStart
                    Section("This week") {
                        LabeledContent {
                            Text(Words.count(counts.repeatCorrectionsThisWeek)).monospacedDigit()
                        } label: {
                            Text("Repeat corrections")
                            Text(counts.repeatCorrectionsLastWeek.map { "Last week \($0)" }
                                 ?? "Last week: " + ReviewText.notMeasured)
                        }
                        LabeledContent {
                            Text(Words.count(counts.violationsThisWeek)).monospacedDigit()
                        } label: {
                            Text("Violations")
                        }
                        LabeledContent {
                            Text("\(counts.rulesApproved)").monospacedDigit()
                        } label: {
                            Text("Rules approved")
                        }
                        LabeledContent {
                            Text(counts.draftCap.map { "\(counts.draftsToday) of \($0)" } ?? "\(counts.draftsToday)").monospacedDigit()
                        } label: {
                            Text("Drafts today")
                            if counts.draftCap == nil { Text("Daily limit: " + ReviewText.notMeasured) }
                        }
                    }
                    if counts.weeks.isEmpty {
                        Section("Repeat corrections per week") {
                            Text(ReviewText.notMeasured).foregroundStyle(.secondary)
                        }
                        Section("Violations per week") {
                            Text(ReviewText.notMeasured).foregroundStyle(.secondary)
                        }
                    } else {
                    Section {
                        Chart(counts.weeks, id: \.weekStart) { week in
                            BarMark(x: .value("Week", Self.label(week.weekStart)),
                                    y: .value("Repeat corrections", week.repeatCorrections))
                            .foregroundStyle(week.weekStart == current ? Color.accentColor : Color.accentColor.opacity(0.4))
                        }
                        .frame(height: 180)
                        .accessibilityLabel("Repeat corrections per week")
                    } header: {
                        Text("Repeat corrections per week")
                    } footer: {
                        Text(Self.caption(counts.weeks.map(\.repeatCorrections), noun: "repeat corrections")
                             + " A shorter bar is better. The solid bar is this week.")
                    }
                    Section {
                        Chart(counts.weeks, id: \.weekStart) { week in
                            BarMark(x: .value("Week", Self.label(week.weekStart)),
                                    y: .value("Violations", week.violations))
                            .foregroundStyle(week.weekStart == current ? Color.orange : Color.orange.opacity(0.4))
                        }
                        .frame(height: 180)
                        .accessibilityLabel("Violations of approved rules per week")
                    } header: {
                        Text("Violations per week")
                    } footer: {
                        Text(Self.caption(counts.weeks.map(\.violations), noun: "violations")
                             + " A shorter bar is better. The solid bar is this week.")
                    }
                    }
                } else {
                    Section { Text(ReviewText.appearsWhileOnline).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Learning")
            .accessibilityIdentifier("screen.learning")
        }
    }

    /// "Nov 16" for the week that starts on 2026-11-16, in the phone's calendar.
    static func label(_ weekStart: String) -> String {
        let parts = weekStart.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let date = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        else { preconditionFailure("weekStart \(weekStart) is not a YYYY-MM-DD date") }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// The takeaway: whether the last week sits below or above the first week of the chart.
    static func caption(_ values: [Int], noun: String) -> String {
        guard let first = values.first, let last = values.last, values.count >= 2 else {
            return "Each bar counts the \(noun) of one week."
        }
        if last < first { return "The \(noun) fell from \(first) to \(last) a week." }
        if last > first { return "The \(noun) rose from \(first) to \(last) a week." }
        return "The \(noun) stayed at \(last) a week."
    }
}
