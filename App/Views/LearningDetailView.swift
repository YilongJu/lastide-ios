import LastideKit
import SwiftUI

// The detail of one learning row, with every field of Table 8 of the learning evidence design. A turn offers Show My
// Words, which reads its words live from the PC. The words live in the model's memory until this screen closes or the
// app leaves the active state, and the words view does not allow selection, so they never reach the clipboard.

/// One field: a name and its value.
private struct Field: View {
    let name: String
    let value: String
    var identifier: String?

    init(_ name: String, _ value: String, identifier: String? = nil) {
        self.name = name
        self.value = value
        self.identifier = identifier
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.footnote).foregroundStyle(.secondary)
            Text(value)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier ?? "field")
    }
}

/// A link to another list or row of the drill-down.
private struct RouteLink: View {
    let title: String
    let route: LearningRoute

    var body: some View {
        NavigationLink(title, value: AppRoute.learning(route))
    }
}

/// One message the person typed, or one review comment.
struct LearningTurnView: View {
    @Bindable var model: AppModel
    let turn: LearningTurn

    private var thresholds: LearningThresholds? { model.learningThresholds }

    var body: some View {
        List {
            Section("Message") {
                Field("Typed", LearningDates.time(turn.at))
                Field("Project", turn.projectName)
                Field("Agent", LearningText.agent(turn))
                Field("Signal", turn.signal.map(Words.signal) ?? LearningText.notKept)
                Field("Category", turn.category.map(LearningText.category) ?? LearningText.notKept)
            }
            wordsSection
            Section("Scores") {
                Field("Correction score", LearningText.kindScoreLine(turn, threshold: thresholds?.kind ?? 0.4), identifier: "kindScore")
                Field("Every-project score", turn.scopeScore.map(LearningText.scopeScore) ?? LearningText.scoreNotKept)
                Field("Question version", turn.questionVersion.map(String.init) ?? LearningText.notKept)
            }
            Section("Counting") {
                Field("Counts", LearningText.counted(turn), identifier: "counts")
                if let countedAt = turn.countedAt { Field("Counted since", LearningDates.time(countedAt)) }
            }
            if let group = turn.group {
                Section("Group") {
                    Field("Group", LearningText.groupLine(size: group.size, state: group.state))
                    Field("Group score", group.oneRulePrevents.map {
                        LearningText.groupScore($0, ready: thresholds?.groupReady ?? 0.5, wait: thresholds?.groupWait ?? 0.3)
                    } ?? LearningText.groupScoreLocal)
                    Field("How it joined", LearningText.join(group.joinedBy))
                    if let firstAt = group.firstAt { Field("First said", LearningDates.time(firstAt)) }
                    RouteLink(title: "Show the Group", route: .list(.group(id: group.id), expected: group.size))
                    if let draftId = group.draftId { RouteLink(title: "Show the Draft", route: .list(.draft(id: draftId), expected: nil)) }
                    if let ruleId = group.ruleId { RouteLink(title: "Show the Rule", route: .list(.rule(id: ruleId), expected: nil)) }
                }
            }
            ForEach(Array(turn.violations.enumerated()), id: \.offset) { index, violation in
                Section {
                    Field("Repeats the rule", violation.ruleText)
                    Field("Approved", LearningDates.time(violation.ruleApprovedAt))
                    Field("State", LearningText.ruleState(violation.ruleState))
                    Field("Coverage score", violation.covered.map { LearningText.coveredScore($0, threshold: thresholds?.coverage ?? 0.7) }
                          ?? LearningText.scoreNotKept)
                    Field("Repeats score", violation.repeats.map(LearningText.repeatsAnswer) ?? LearningText.scoreNotKept)
                    Field("Contradicts score", LearningText.score(violation.contradicts))
                    Field("Answered", LearningDates.time(violation.answeredAt))
                    RouteLink(title: "Show the Rule", route: .list(.rule(id: violation.ruleId), expected: nil))
                } header: {
                    if index == 0 { Text(LearningText.violationCount(turn.violations.count + (turn.violationsLeftOut ?? 0))) }
                }
            }
            if let leftOut = turn.violationsLeftOut, leftOut > 0 {
                Section { Text(LearningText.violationsLeftOut(leftOut)).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Message")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { model.closeWords() }
        .accessibilityIdentifier("screen.learningTurn")
    }

    private var words: OpenWords? {
        guard let open = model.learningWords, open.ref == turn.ref else { return nil }
        return open
    }

    @ViewBuilder
    private var wordsSection: some View {
        Section("Your words") {
            switch words?.phase {
            case nil:
                Button(LearningText.showWords) { model.showWords(ref: turn.ref) }.accessibilityIdentifier("showWords")
            case .asking?:
                HStack(spacing: 10) {
                    ProgressView()
                    Text(LearningText.asking).foregroundStyle(.secondary)
                }
            case .words(let text)?:
                VStack(alignment: .leading, spacing: 4) {
                    Text("\u{201C}\(text)\u{201D}").italic().textSelection(.disabled).privacySensitive()
                    Text(LearningText.wordsFrom).font(.footnote).foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("words")
            case .removed?:
                wordsLine(turn.agent == nil ? LearningText.commentRemoved : LearningText.wordsRemoved)
            case .gone?:
                wordsLine(LearningText.rowChanged)
            case .limited(let nextAt)?:
                wordsLine(LearningText.wordsLimited(LearningDates.clockTime(nextAt)))
            case .offline?:
                wordsLine(LearningText.appearsWhileOnline)
            case .noAnswer?:
                VStack(alignment: .leading, spacing: 8) {
                    Text(LearningText.noAnswer).accessibilityIdentifier("wordsState")
                    Button(LearningText.tryAgain) { model.showWords(ref: turn.ref) }.buttonStyle(.bordered)
                }
            case .needsUpdate?:
                wordsLine(LearningText.updatePC)
            case .demo?:
                wordsLine(LearningText.demoWords)
            }
        }
    }

    private func wordsLine(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).accessibilityIdentifier("wordsState")
    }
}

/// One approved rule.
struct LearningRuleView: View {
    let rule: LearningRule

    var body: some View {
        List {
            Section("Rule") {
                Field("Text", rule.text)
                Field("State", LearningText.ruleState(rule.state))
                Field("Source", LearningText.ruleSource(rule.source))
                Field("Category", LearningText.category(rule.category))
                Field("Scope", Words.scope(rule.scope))
                Field("Approved", LearningDates.time(rule.approvedAt))
            }
            Section("Counters") {
                Field("Corrections before approval", "\(rule.correctionsBeforeApproval)")
                Field("Violations since approval", Words.count(rule.violations))
                RouteLink(title: "Show the Violations", route: .list(.rule(id: rule.id), expected: rule.violations))
            }
            Section("Where it came from") {
                if let draftId = rule.draftId {
                    RouteLink(title: "Show the Draft", route: .list(.draft(id: draftId), expected: nil))
                } else {
                    Field("Draft it came from", "None")
                }
                if let runId = rule.runId {
                    RouteLink(title: "Show the Run", route: .list(.run(id: runId), expected: nil))
                } else {
                    Field("Drafting run", "None")
                }
            }
        }
        .navigationTitle("Rule")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("screen.learningRule")
    }
}

/// One draft.
struct LearningDraftView: View {
    let draft: LearningDraft

    var body: some View {
        List {
            Section("Draft") {
                Field("Text", draft.text ?? "An import's text stays on your PC.")
                Field("Kind", LearningText.draftKind(draft.draftKind))
                Field("Status", LearningText.draftStatus(draft.status))
                Field("Written", LearningDates.time(draft.createdAt))
                Field("Category", LearningText.category(draft.category))
            }
            Section("Corrections") {
                Field("Corrections", "\(draft.evidenceCount)")
                RouteLink(title: "Show the Corrections", route: .list(.draft(id: draft.id), expected: draft.evidenceCount))
                if let groupId = draft.groupId { RouteLink(title: "Show the Group", route: .list(.group(id: groupId), expected: nil)) }
            }
            Section("Drafting run") {
                if let runId = draft.runId {
                    RouteLink(title: "Show the Run", route: .list(.run(id: runId), expected: nil))
                } else {
                    Field("Drafting run", "None")
                }
            }
        }
        .navigationTitle("Draft")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("screen.learningDraft")
    }
}

/// One drafting run: its route, Claude Code version, models, tokens and cost estimate (decision E5).
struct LearningRunView: View {
    let run: LearningRun

    var body: some View {
        List {
            Section("Drafting run") {
                Field("Route", LearningText.route(run.route))
                Field("Job", LearningText.job(run.job))
                Field("State", LearningText.runState(run.state))
                Field("Outcome", LearningText.outcome(run.outcome))
                Field("Started", LearningDates.time(run.startedAt))
                Field("Ended", run.endedAt.map(LearningDates.time) ?? LearningText.notEnded)
            }
            Section("Claude Code") {
                Field("Claude Code version", run.version.map(LearningText.claudeCode) ?? LearningText.notKept, identifier: "runVersion")
                if run.route == .terminal {
                    Field("Model", run.requestedModel.map(LearningText.terminalRun) ?? LearningText.modelNotKept)
                } else {
                    Field("Model asked for", run.requestedModel ?? LearningText.modelNotKept, identifier: "requestedModel")
                    Field("Model that answered", run.reportedModel ?? LearningText.modelNotKept, identifier: "reportedModel")
                }
            }
            Section("Tokens and cost") {
                if let tokens = run.tokens {
                    Field("Tokens", LearningText.tokens(tokens))
                    Field("Cache writes", LearningText.cacheWrites(tokens))
                } else {
                    Field("Tokens", LearningText.noTokens)
                }
                Field("Cost", run.costMicros.map { LearningText.cost(micros: $0) } ?? LearningText.costMissing(run.costMissing),
                      identifier: "runCost")
            }
            Section("Results") {
                Field("Drafts written", "\(run.drafts)" + (run.recordedDrafts.map { " " + LearningText.recordedDrafts($0) } ?? ""))
                RouteLink(title: "Show the Drafts", route: .list(.run(id: run.id), expected: run.drafts))
                Field("Groups sent", "\(run.groups)")
                Field("Matched rules you approved", "\(run.reinforced)")
                Field("Conflicts", "\(run.conflicts)")
                Field("Skipped", "\(run.skipped)")
            }
        }
        .navigationTitle("Drafting run")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("screen.learningRun")
    }
}

/// One joined group, the head of the list of its members.
struct LearningGroupView: View {
    @Bindable var model: AppModel
    let group: LearningGroup

    var body: some View {
        let thresholds = model.learningThresholds
        List {
            Section("Group") {
                Field("Members", "\(group.size)")
                Field("Category", group.category.map(LearningText.category) ?? LearningText.notKept)
                Field("State", LearningText.groupState(group.state))
                Field("Group score", group.oneRulePrevents.map {
                    LearningText.groupScore($0, ready: thresholds?.groupReady ?? 0.5, wait: thresholds?.groupWait ?? 0.3)
                } ?? LearningText.groupScoreLocal)
                if let formedAt = group.formedAt { Field("Formed", LearningDates.time(formedAt)) }
            }
            Section("Links") {
                RouteLink(title: "Show the Members", route: .list(.group(id: group.id), expected: group.size))
                if let draftId = group.draftId { RouteLink(title: "Its draft", route: .list(.draft(id: draftId), expected: nil)) }
                if let ruleId = group.ruleId { RouteLink(title: "Its rule", route: .list(.rule(id: ruleId), expected: nil)) }
            }
        }
        .navigationTitle("Group")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("screen.learningGroup")
    }
}
