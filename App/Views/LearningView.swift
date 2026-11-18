import Charts
import LastideKit
import SwiftUI

/// The Learning dashboard: the four numbers and the two weekly charts (plan section 4.3, protocol Table 23).
struct LearningView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationStack {
            List {
                if model.isDemo {
                    Section { Text(AppText.sampleData).font(.footnote).foregroundStyle(.secondary) }
                }
                if let counts = model.store.counts {
                    Section {
                        Text("Repeat corrections this week: \(counts.repeatCorrectionsThisWeek) (last week \(counts.repeatCorrectionsLastWeek))")
                        Text("Rules approved: \(counts.rulesApproved)")
                        Text("Violations this week: \(counts.violationsThisWeek)")
                        Text("Drafts today: \(counts.draftsToday) of \(counts.draftCap)")
                    }
                    Section {
                        Chart(counts.weeks, id: \.weekStart) { week in
                            BarMark(x: .value("Week", Self.label(week.weekStart)),
                                    y: .value("Repeat corrections", week.repeatCorrections))
                        }
                        .frame(height: 180)
                        .accessibilityLabel("Repeat corrections per week")
                    } header: {
                        Text("Repeat corrections per week")
                    } footer: {
                        Text(Self.caption(counts.weeks.map(\.repeatCorrections), noun: "repeat corrections")
                             + " A shorter bar is better.")
                    }
                    Section {
                        Chart(counts.weeks, id: \.weekStart) { week in
                            BarMark(x: .value("Week", Self.label(week.weekStart)),
                                    y: .value("Violations", week.violations))
                            .foregroundStyle(.orange)
                        }
                        .frame(height: 180)
                        .accessibilityLabel("Violations of approved rules per week")
                    } header: {
                        Text("Violations per week")
                    } footer: {
                        Text(Self.caption(counts.weeks.map(\.violations), noun: "violations") + " A shorter bar is better.")
                    }
                } else {
                    Section { Text(ReviewText.appearsWhileOnline).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Learning")
            .accessibilityIdentifier("screen.learning")
        }
    }

    /// "11-16" for the week that starts on 2026-11-16.
    static func label(_ weekStart: String) -> String { String(weekStart.suffix(5)) }

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
