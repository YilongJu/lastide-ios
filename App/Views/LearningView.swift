import Charts
import LastideKit
import SwiftUI

/// The Learning dashboard (learning evidence design, sections 3 and 7; protocol Table 23). Each number and each bar
/// opens the list of rows behind it, with its definition, its exact rule and what it leaves out.
struct LearningView: View {
    @Bindable var model: AppModel
    @Binding var path: [AppRoute]
    /// Opens the Settings tab from the demo banner.
    let onPair: () -> Void

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if model.isDemo {
                    Section { DemoBanner(text: AppText.sampleNumbers, onPair: onPair) }
                }
                if let counts = model.store.counts {
                    content(counts)
                } else {
                    Section { Text(ReviewText.appearsWhileOnline).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle(LearningText.title)
            .appDestinations(model: model)
            .accessibilityIdentifier("screen.learning")
        }
    }

    @ViewBuilder
    private func content(_ counts: Counts) -> some View {
        let clock = model.learningClock
        let thisWeek = counts.weeks.last?.weekStart ?? LearningDates.weekStart(of: clock)
        let today = counts.today ?? LearningDates.day(of: clock)
        let pcName = model.isDemo ? "your PC" : (model.selectedRecord?.pcName ?? "your PC")
        Section {
            if !model.isDemo, model.selectedRecord != nil {
                Text(LearningText.from(pcName, age: AppText.age(ms: max(0, clock - counts.sentAt))))
                    .accessibilityIdentifier("learningAge")
            }
            if model.isDemo || model.pcSchema >= 4 {
                Text(LearningText.tapHint).font(.footnote).foregroundStyle(.secondary)
            } else {
                Label(LearningText.updatePC, systemImage: "arrow.down.circle")
                    .font(.footnote)
                    .accessibilityIdentifier("learningUpdatePC")
            }
            if let line = measuredLine(counts) {
                Text(line).font(.footnote).foregroundStyle(.secondary)
            }
        }
        Section(LearningDates.isCurrentWeek(thisWeek, clock: clock) ? LearningText.sectionWeek : LearningText.weekOf(thisWeek)) {
            MetricRow(metric: .repeats, value: Words.count(counts.repeatCorrectionsThisWeek),
                      lines: [LearningText.line(.repeats, pcName: pcName),
                              LearningText.repeatsLastWeek(byNow: counts.repeatCorrectionsLastWeekByNow ?? nil,
                                                           all: counts.repeatCorrectionsLastWeek)],
                      route: .list(.repeatWeek(weekStart: thisWeek), expected: nil))
            MetricRow(metric: .violations, value: Words.count(counts.violationsThisWeek),
                      lines: [LearningText.line(.violations, pcName: pcName)]
                        + ((counts.violationsLastWeekByNow ?? nil).map { [LearningText.violationsLastWeek(byNow: $0)] } ?? []),
                      route: .list(.violationWeek(weekStart: thisWeek), expected: nil))
            if let approved = counts.rulesApprovedThisWeek {
                MetricRow(metric: .rulesApproved, value: "\(approved)", lines: [LearningText.line(.rulesApproved, pcName: pcName)],
                          route: .list(.rulesApprovedWeek(weekStart: thisWeek), expected: nil))
            }
        }
        Section(today == LearningDates.day(of: clock) ? LearningText.sectionToday : today) {
            MetricRow(metric: .drafts, value: "\(counts.draftsToday)", lines: [LearningText.line(.drafts, pcName: pcName)],
                      route: .list(.draftsToday(day: today), expected: nil))
            if let runs = counts.draftingRunsToday, let cap = counts.draftingRunCap {
                let finished = counts.draftingRunsFinishedToday
                MetricRow(metric: .runs, value: ReviewText.draftingRuns(runs, cap: cap),
                          lines: [LearningText.line(.runs, pcName: pcName, finished: finished,
                                                    notFinished: finished.map { runs - $0 })],
                          route: .list(.runsToday(day: today), expected: nil))
            }
        }
        Section(LearningText.sectionNow) {
            MetricRow(metric: .rulesOn, value: "\(counts.rulesApproved)", lines: [LearningText.line(.rulesOn, pcName: pcName)],
                      route: .list(.rulesOn, expected: nil))
        }
        WeekChart(chart: .repeats, counts: counts, clock: clock, onWeek: open)
        WeekChart(chart: .violations, counts: counts, clock: clock, onWeek: open)
    }

    private func open(_ route: LearningRoute) { path.append(.learning(route)) }

    /// When rule learning started to measure, from `measuredFrom` of revision 4.
    private func measuredLine(_ counts: Counts) -> String? {
        switch counts.measuredFrom {
        case .none: return nil
        case .some(.none): return LearningText.notStarted
        case .some(.some(let from)): return LearningText.measuredFrom(LearningDates.day(of: from))
        }
    }
}

/// One number of Table 5: its label and value, the lines under it, and a link to its list.
struct MetricRow: View {
    let metric: LearningMetric
    let value: String
    let lines: [String]
    let route: LearningRoute
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        NavigationLink(value: AppRoute.learning(route)) {
            VStack(alignment: .leading, spacing: 3) {
                if typeSize.isAccessibilitySize {
                    Text(LearningText.label(metric))
                    Text(value).font(.title3.weight(.semibold)).monospacedDigit()
                } else {
                    HStack(alignment: .firstTextBaseline) {
                        Text(LearningText.label(metric))
                        Spacer(minLength: 8)
                        Text(value).font(.title3.weight(.semibold)).monospacedDigit()
                    }
                }
                ForEach(lines, id: \.self) { line in
                    Text(line).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        }
        .accessibilityIdentifier("metric.\(metric.rawValue)")
    }
}

/// One weekly chart: a bar per measured week, the current week as an outline, a partly measured week faded, the
/// caption of section 3.3, and a folded Weeks group whose rows open each week's list.
struct WeekChart: View {
    let chart: LearningChart
    let counts: Counts
    let clock: Int
    let onWeek: (LearningRoute) -> Void
    @State private var showWeeks = false

    private struct Bar: Identifiable {
        let week: WeekCount
        let label: String
        let value: Int
        let state: LearningSpan
        let current: Bool
        var id: String { week.weekStart }
    }

    private var title: String { chart == .repeats ? LearningText.repeatChart : LearningText.violationChart }
    private var tint: Color { chart == .repeats ? .accentColor : .orange }

    private var bars: [Bar] {
        let states = counts.captionWeeks(chart)
        return counts.weeks.enumerated().map { index, week in
            let current = LearningDates.isCurrentWeek(week.weekStart, clock: clock) || (index == counts.weeks.count - 1 && !counts.hasRevisionFour)
            // The axis shows the date only, so a narrow bar does not cut "Nov 16 so far" to "Nov 1...". The outline,
            // the legend line and the spoken value say "so far".
            let label = LearningDates.label(week.weekStart)
            return Bar(week: week, label: label,
                       value: chart == .repeats ? week.repeatCorrections : week.violations, state: states[index].state,
                       current: current)
        }
    }

    private func route(_ week: WeekCount) -> LearningRoute {
        .list(chart == .repeats ? .repeatWeek(weekStart: week.weekStart) : .violationWeek(weekStart: week.weekStart),
              expected: nil)
    }

    var body: some View {
        Section {
            if counts.weeks.isEmpty {
                Text(ReviewText.notMeasured).foregroundStyle(.secondary)
            } else {
                let shown = bars.filter { $0.state != .notMeasured }
                if shown.isEmpty {
                    Text(LearningText.notMeasured).foregroundStyle(.secondary)
                } else {
                    chartView(shown)
                    if shown.contains(where: \.current) {
                        Text(LearningText.currentWeekLegend).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                DisclosureGroup(LearningText.weeks, isExpanded: $showWeeks) {
                    ForEach(bars.reversed()) { bar in
                        NavigationLink(value: AppRoute.learning(route(bar.week))) {
                            LabeledContent {
                                // An unmeasured week has no number: its state line says so once.
                                Text(bar.state == .notMeasured ? "" : "\(bar.value)").monospacedDigit()
                            } label: {
                                Text(bar.current ? LearningText.soFar(LearningText.weekOf(bar.week.weekStart))
                                     : LearningText.weekOf(bar.week.weekStart))
                                Text(LearningText.weekState(bar.state, waiting: bar.week.waiting))
                            }
                        }
                        .accessibilityIdentifier("week.\(chart == .repeats ? "repeats" : "violations").\(bar.week.weekStart)")
                    }
                }
                .accessibilityIdentifier("weeks.\(chart == .repeats ? "repeats" : "violations")")
            }
        } header: {
            Text(title)
        } footer: {
            if !counts.weeks.isEmpty { Text(counts.caption(chart)) }
        }
    }

    private func chartView(_ shown: [Bar]) -> some View {
        Chart(shown) { bar in
            BarMark(x: .value("Week", bar.label), y: .value(title, bar.value), width: .ratio(0.6))
                .foregroundStyle(bar.current ? tint.opacity(0.12) : bar.state == .partial ? tint.opacity(0.4) : tint)
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let plotFrame = proxy.plotFrame {
                    let plot = geometry[plotFrame]
                    let band = plot.width / CGFloat(max(shown.count, 1))
                    ForEach(shown.filter(\.current)) { bar in
                        if let x = proxy.position(forX: bar.label), let top = proxy.position(forY: bar.value),
                           let bottom = proxy.position(forY: 0) {
                            Rectangle()
                                .stroke(tint, style: StrokeStyle(lineWidth: 2))
                                .frame(width: band * 0.6, height: max(2, bottom - top))
                                .position(x: plot.minX + x, y: plot.minY + (top + bottom) / 2)
                        }
                    }
                    Rectangle().fill(Color.clear).contentShape(Rectangle())
                        .onTapGesture { location in
                            guard let label: String = proxy.value(atX: location.x - plot.minX),
                                  let bar = shown.first(where: { $0.label == label })
                            else { return }
                            onWeek(route(bar.week))
                        }
                }
            }
        }
        .frame(height: 180)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(shown.map { "\($0.current ? LearningText.soFar($0.label) : $0.label): \($0.value)" }.joined(separator: ", "))
        .accessibilityHint("Open the Weeks group below to see each week's list.")
        .accessibilityIdentifier("chart.\(chart == .repeats ? "repeats" : "violations")")
    }
}

/// The dates of the learning screens. A week starts on the PC's Monday, and its `weekStart` names that date.
enum LearningDates {
    /// The date `YYYY-MM-DD` as a local date, or nil when it does not read.
    static func date(_ text: String) -> Date? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// "Nov 16" for 2026-11-16.
    static func label(_ weekStart: String) -> String {
        guard let date = date(weekStart) else { preconditionFailure("weekStart \(weekStart) is not a YYYY-MM-DD date") }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// Whether the clock lies in the week that starts on `weekStart`.
    static func isCurrentWeek(_ weekStart: String, clock: Int) -> Bool {
        guard let start = date(weekStart), let end = Calendar.current.date(byAdding: .day, value: 7, to: start) else { return false }
        let now = Date(timeIntervalSince1970: Double(clock) / 1_000)
        return now >= start && now < end
    }

    /// The local date of a protocol time, as `YYYY-MM-DD`.
    static func day(of time: Int) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: Double(time) / 1_000))
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// The Monday of the local week that holds the time, as `YYYY-MM-DD`.
    static func weekStart(of time: Int) -> String {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        let date = Date(timeIntervalSince1970: Double(time) / 1_000)
        let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date
        return day(of: Int(start.timeIntervalSince1970 * 1_000))
    }

    /// "Nov 18, 2026 at 10:41".
    static func time(_ time: Int) -> String {
        Date(timeIntervalSince1970: Double(time) / 1_000).formatted(date: .abbreviated, time: .shortened)
    }

    /// "10:41".
    static func clockTime(_ time: Int) -> String {
        Date(timeIntervalSince1970: Double(time) / 1_000).formatted(date: .omitted, time: .shortened)
    }
}
