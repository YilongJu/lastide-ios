import LastideKit
import SwiftUI

/// One screen of the learning drill-down (learning evidence design, Figure 1).
enum LearningRoute: Hashable {
    /// A list. `expected` is the number the person tapped when `counts` does not hold it, such as a group's size.
    case list(LearningSubject, expected: Int?)
    case turn(LearningTurn)
    case rule(LearningRule)
    case draft(LearningDraft)
    case run(LearningRun)
    case group(LearningGroup)

    /// The list this screen shows, or nil for a row's detail.
    var subject: LearningSubject? {
        if case .list(let subject, _) = self { return subject }
        return nil
    }
}

/// A navigation value of the Library and Learning tabs.
enum AppRoute: Hashable {
    /// A rule of the Library.
    case rule(String)
    /// A learning list or row.
    case learning(LearningRoute)
}

extension View {
    /// The screens that the Library and Learning tabs push.
    func appDestinations(model: AppModel) -> some View {
        navigationDestination(for: AppRoute.self) { route in
            switch route {
            case .rule(let id): RuleDetailView(model: model, ruleID: id)
            case .learning(let route): LearningScreen(model: model, route: route)
            }
        }
    }
}

/// The screen of one learning route.
struct LearningScreen: View {
    @Bindable var model: AppModel
    let route: LearningRoute

    var body: some View {
        switch route {
        case .list(let subject, let expected): LearningListView(model: model, subject: subject, expected: expected)
        case .turn(let turn): LearningTurnView(model: model, turn: turn)
        case .rule(let rule): LearningRuleView(rule: rule)
        case .draft(let draft): LearningDraftView(draft: draft)
        case .run(let run): LearningRunView(run: run)
        case .group(let group): LearningGroupView(model: model, group: group)
        }
    }
}

/// A list: its number, definition, rule, thresholds and what it leaves out, then its rows, 50 at a time
/// (learning evidence design, section 7).
struct LearningListView: View {
    @Bindable var model: AppModel
    let subject: LearningSubject
    let expected: Int?

    private var list: LearningList? { model.learningLists[subject] }
    private var counts: Counts? { model.store.counts }
    /// The number the person tapped: from `counts` while it holds one, else the row's own number.
    private var number: Int? { counts?.number(for: subject) ?? expected }

    var body: some View {
        List {
            Section {
                Text(LearningText.listTitle(subject)).font(.headline)
                if let list, list.phase == .shown {
                    Text(LearningText.value(list.value)).monospacedDigit().accessibilityIdentifier("listValue")
                    if let asOf = list.asOf { Text(LearningText.countedAt(LearningDates.time(asOf))).font(.footnote).foregroundStyle(.secondary) }
                } else if let number {
                    Text(LearningText.value(number)).monospacedDigit().accessibilityIdentifier("listValue")
                }
                Text(LearningText.listDefinition(subject, thresholds: list?.thresholds ?? model.learningThresholds,
                                                 cap: counts?.draftingRunCap))
                Text(LearningText.listRule(subject, thresholds: list?.thresholds ?? model.learningThresholds))
                    .font(.footnote).foregroundStyle(.secondary)
                if let thresholds = list?.thresholds ?? model.learningThresholds {
                    Text(LearningText.thresholds(thresholds)).font(.footnote).foregroundStyle(.secondary)
                }
                if let list, list.phase == .shown { leftOutLines(list) }
                if let difference = list?.mismatch(expected: number) {
                    Label(LearningText.mismatch(counted: difference.counted, listed: difference.listed),
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Color.statusText)
                        .accessibilityIdentifier("listMismatch")
                }
                if list?.restarted == true {
                    Text(LearningText.changed).font(.footnote).foregroundStyle(.secondary)
                }
                if model.isDemo {
                    Text(LearningText.demoList).font(.footnote).foregroundStyle(.secondary)
                }
            }
            if let head = list?.head, list?.phase == .shown {
                Section("Details") { HeadSummary(head: head) }
            }
            rowsSection
        }
        .navigationTitle(LearningText.listScreenTitle(subject))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.openList(subject) }
        .onChange(of: model.screenGeneration) { _, _ in model.openList(subject) }
        .accessibilityIdentifier("screen.learningList")
    }

    @ViewBuilder
    private func leftOutLines(_ list: LearningList) -> some View {
        if list.leftOut.untraced > 0 { Text(LearningText.untraced(list.leftOut.untraced)).font(.footnote) }
        if list.leftOut.afterThisWeek > 0 { Text(LearningText.afterThisWeek(list.leftOut.afterThisWeek)).font(.footnote) }
        if list.leftOut.older > 0, let line = LearningText.older(list.leftOut.older, subject: subject) {
            Text(line).font(.footnote)
        }
    }

    @ViewBuilder
    private var rowsSection: some View {
        Section {
            switch list?.phase {
            case .shown?:
                if let list {
                    if list.rows.isEmpty {
                        Text(LearningText.empty).foregroundStyle(.secondary).accessibilityIdentifier("listEmpty")
                    }
                    ForEach(Array(list.rows.enumerated()), id: \.offset) { _, row in
                        NavigationLink(value: AppRoute.learning(route(row))) { LearningRowView(row: row) }
                    }
                    if list.next != nil {
                        Button(LearningText.showMore) { model.showMore(subject) }.accessibilityIdentifier("showMore")
                    }
                }
            case .asking?, nil:
                HStack(spacing: 10) {
                    ProgressView()
                    Text(LearningText.asking).foregroundStyle(.secondary)
                }
            case .offline?:
                Text(LearningText.appearsWhileOnline).foregroundStyle(.secondary).accessibilityIdentifier("listOffline")
            case .needsUpdate?:
                Label(LearningText.updatePC, systemImage: "arrow.down.circle").accessibilityIdentifier("listUpdatePC")
            case .noAnswer?:
                retry(LearningText.noAnswer)
            case .changedTooOften?:
                retry(LearningText.changedTooOften)
            case .gone?:
                Text(LearningText.gone).foregroundStyle(.secondary)
            case .limited?:
                retry(LearningText.pagesLimited)
            case .blocked?:
                Text(LearningText.blocked).foregroundStyle(.secondary)
            }
        } header: {
            Text("Rows")
        } footer: {
            if let list, list.phase == .shown, list.total > 0 { Text(LearningText.listed(list.rows.count, of: list.total)) }
        }
    }

    private func retry(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text).accessibilityIdentifier("listRetry")
            Button(LearningText.tryAgain) { model.retryList(subject) }.buttonStyle(.bordered)
        }
    }

    private func route(_ row: LearningRow) -> LearningRoute {
        switch row {
        case .turn(let turn): return .turn(turn)
        case .rule(let rule): return .rule(rule)
        case .draft(let draft): return .draft(draft)
        case .run(let run): return .run(run)
        }
    }
}

/// One row of a list, in two or three lines.
struct LearningRowView: View {
    let row: LearningRow

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            switch row {
            case .turn(let turn):
                Text(LearningDates.time(turn.at) + " · " + turn.projectName)
                Text(LearningText.agent(turn) + " · " + (turn.signal.map(Words.signal) ?? LearningText.notKept))
                    .font(.footnote).foregroundStyle(.secondary)
                if !turn.counted {
                    Text(LearningText.counted(turn)).font(.footnote).foregroundStyle(.secondary)
                }
                if !turn.violations.isEmpty {
                    Text(LearningText.violationCount(turn.violations.count)).font(.footnote).foregroundStyle(Color.statusText)
                }
            case .rule(let rule):
                Text(rule.text).foregroundStyle(rule.state == .on ? .primary : .secondary)
                Text(LearningText.ruleState(rule.state) + " · Approved " + Words.date(rule.approvedAt))
                    .font(.footnote).foregroundStyle(.secondary)
            case .draft(let draft):
                Text(draft.text ?? LearningText.draftKind(draft.draftKind))
                Text(LearningText.draftStatus(draft.status) + " · " + LearningDates.time(draft.createdAt))
                    .font(.footnote).foregroundStyle(.secondary)
            case .run(let run):
                Text(LearningDates.time(run.startedAt))
                Text(LearningText.runState(run.state) + " · " + (run.drafts == 1 ? "1 draft" : "\(run.drafts) drafts"))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// The item a list explains, in a few lines, with a link to its whole detail.
struct HeadSummary: View {
    let head: LearningHead

    var body: some View {
        switch head {
        case .group(let group):
            NavigationLink(value: AppRoute.learning(.group(group))) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(LearningText.groupLine(size: group.size, state: group.state))
                    if let score = group.oneRulePrevents {
                        Text("Group score \(LearningText.score(score))").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        case .rule(let rule):
            NavigationLink(value: AppRoute.learning(.rule(rule))) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(rule.text)
                    Text(LearningText.ruleState(rule.state) + " · Approved " + Words.date(rule.approvedAt))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        case .draft(let draft):
            NavigationLink(value: AppRoute.learning(.draft(draft))) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(draft.text ?? LearningText.draftKind(draft.draftKind))
                    Text(LearningText.draftStatus(draft.status)).font(.footnote).foregroundStyle(.secondary)
                }
            }
        case .run(let run):
            NavigationLink(value: AppRoute.learning(.run(run))) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(LearningDates.time(run.startedAt))
                    Text(LearningText.runState(run.state)).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }
}
