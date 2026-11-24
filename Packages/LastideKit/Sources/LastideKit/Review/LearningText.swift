import Foundation

// Every sentence of the Learning screens (learning evidence design, sections 3, 5.2 and 7; Tables 5, 8 and 11). The
// desktop's Learning tab holds the same texts in `learningTexts.ts`, so both screens use one set of words. The texts
// live in the package, so they read while the PC is offline. A text says "the model" for the classifier.

/// One bar of a chart, as the caption reads it.
public struct CaptionWeek: Hashable, Sendable {
    public let weekStart: String
    /// Null for a week without a number.
    public let value: Int?
    public let state: LearningSpan

    /// Names one bar.
    public init(weekStart: String, value: Int?, state: LearningSpan) {
        self.weekStart = weekStart
        self.value = value
        self.state = state
    }
}

/// Which chart a caption describes.
public enum LearningChart: Sendable { case repeats, violations }

/// One number of the Learning screen (Table 5), in the order the screen shows them.
public enum LearningMetric: String, Hashable, Sendable, CaseIterable {
    case repeats, violations, rulesApproved, drafts, runs, rulesOn
}

/// The sentences of the Learning screens.
public enum LearningText {
    /// A score with two decimals, as every threshold is written.
    public static func score(_ value: Double) -> String { String(format: "%.2f", locale: nil, value) }

    // MARK: The caption (section 3.3)

    /// The caption under one chart: up to four sentences. `weeks` runs oldest first, and the last week holds now.
    /// Sentence 1 compares the oldest and the newest complete, measured week. Sentence 2 counts the changes between
    /// neighbouring complete weeks. A pair with a gap between them is no change. The desktop's `chartCaption` gives the
    /// same text for the same weeks.
    public static func caption(_ chart: LearningChart, weeks: [CaptionWeek], thisWeekSoFar: Int?, lastWeekByNow: Int?) -> String {
        var sentences: [String] = []
        // The last week holds now, so it is never complete.
        let complete = weeks.dropLast().enumerated().filter { $0.element.state == .measured && $0.element.value != nil }
        if complete.count < 2 {
            sentences.append("A change shows after two complete weeks.")
        } else {
            let first = complete.first!.element, last = complete.last!.element
            let a = first.value!, b = last.value!
            let difference = b < a ? "\(a - b) fewer" : b > a ? "\(b - a) more" : "no change"
            let noun = chart == .repeats ? "Repeat corrections" : "Violations"
            sentences.append("\(noun) went from \(a) in the week of \(first.weekStart) to \(b) in the week of \(last.weekStart): \(difference).")
            var down = 0, up = 0, same = 0
            for i in 1..<complete.count where complete[i].offset == complete[i - 1].offset + 1 {
                let change = complete[i].element.value! - complete[i - 1].element.value!
                if change < 0 { down += 1 } else if change > 0 { up += 1 } else { same += 1 }
            }
            let changes = down + up + same
            if complete.count >= 3 && changes == 1 {
                sentences.append(down == 1 ? "The one week-to-week change went down."
                                 : up == 1 ? "The one week-to-week change went up." : "The one week-to-week change stayed the same.")
            } else if complete.count >= 3 && changes > 1 {
                sentences.append("Of the last \(changes) week-to-week changes, \(down) went down, \(up) went up and \(same) stayed the same.")
            }
        }
        if let thisWeekSoFar {
            sentences.append(lastWeekByNow.map { "This week so far: \(thisWeekSoFar). By this time last week: \($0)." }
                             ?? "This week so far: \(thisWeekSoFar).")
        }
        sentences.append(chart == .repeats
                         ? "A shorter bar means fewer repeats. A week with fewer messages has a shorter bar too."
                         : "A shorter bar means fewer violations. A week with fewer messages has a shorter bar too.")
        return sentences.joined(separator: " ")
    }

    // MARK: The numbers (Table 5)

    public static let title = "Learning"
    public static let sectionWeek = "This week so far"
    public static let sectionToday = "Today"
    public static let sectionNow = "Now"
    public static let tapHint = "Tap a number or a bar to see what it counts."

    /// "From WORKSTATION-A, 2 min ago" (Table 4, row 9).
    public static func from(_ pcName: String, age: String) -> String { "From \(pcName), \(age)" }

    /// The heading of a week section that ended, for numbers counted in an earlier week.
    public static func weekOf(_ weekStart: String) -> String { "Week of \(weekStart)" }

    /// The label of one number.
    public static func label(_ metric: LearningMetric) -> String {
        switch metric {
        case .repeats: return "Repeat corrections"
        case .violations: return "Violations"
        case .rulesApproved: return "Rules approved"
        case .drafts: return "Drafts written by drafting runs"
        case .runs: return "Drafting runs"
        case .rulesOn: return "Rules on"
        }
    }

    /// The line under one number. `pcName` names the PC whose midnight the drafts count from.
    public static func line(_ metric: LearningMetric, pcName: String, finished: Int? = nil, notFinished: Int? = nil) -> String {
        switch metric {
        case .repeats: return "Said again, or an approved rule repeated"
        case .violations: return "Messages that repeat an approved rule"
        case .rulesApproved: return "Approved since Monday"
        case .drafts: return "Since midnight on \(pcName)"
        case .runs:
            guard let finished, let notFinished else { return "Started since midnight on \(pcName)" }
            return "\(finished) finished, \(notFinished) did not"
        case .rulesOn: return "In your library, switched on"
        }
    }

    /// "By this time last week: 7. All of last week: 11." under the repeat corrections (Table 4, row 6).
    public static func repeatsLastWeek(byNow: Int?, all: Int?) -> String {
        let all = all.map(String.init) ?? ReviewText.notMeasured
        guard let byNow else { return "All of last week: \(all)." }
        return "By this time last week: \(byNow). All of last week: \(all)."
    }

    /// "By this time last week: 1." under the violations.
    public static func violationsLastWeek(byNow: Int) -> String { "By this time last week: \(byNow)." }

    /// The definition an info line opens for one number (Table 5).
    public static func definition(_ metric: LearningMetric, thresholds: LearningThresholds?, cap: Int?) -> String {
        switch metric {
        case .repeats:
            return "A message counts when a group ties it to something you told an agent before. A message also counts when it repeats a rule you approved earlier. Each message counts once, in the week you typed it."
        case .violations:
            return "You approved a rule, and later told an agent the same thing. The model answered that the message repeats the rule, at \(score(thresholds?.coverage ?? defaultCoverage)) or more. Rules you turned off or deleted since still count."
        case .rulesApproved:
            return "Rules you approved since Monday that you have not deleted. An imported principle counts as one rule."
        case .drafts:
            return "Drafts that a drafting run wrote since midnight, whatever you decided about them. Import drafts come from your own file, so they do not count."
        case .runs:
            let cap = cap.map(String.init) ?? "daily"
            return "Runs that started since midnight. A failed, cancelled or lost run used one of the day's \(cap) runs."
        case .rulesOn:
            return "Every rule that is on and not deleted, of any age."
        }
    }

    /// The coverage threshold the definitions name before a page brings the PC's own value. Table 3 of the design.
    public static let defaultCoverage = 0.7

    public static let repeatChart = "Repeat corrections per week"
    public static let violationChart = "Violations per week"
    public static let weeks = "Weeks"
    public static let notMeasured = "Not measured"
    public static let partial = "Partly measured"
    public static let measured = "Measured"
    public static let notKnownYet = "Not known yet"
    public static let thisWeek = "This week"

    /// "Nov 23 so far", the label of the bar of the week that holds now.
    public static func soFar(_ label: String) -> String { "\(label) so far" }

    /// "1 message waits" or "3 messages wait".
    public static func waiting(_ count: Int) -> String { count == 1 ? "1 message waits" : "\(count) messages wait" }

    /// The state of one week, as its row in the Weeks group reads it.
    public static func weekState(_ state: LearningSpan?, waiting: Int??) -> String {
        switch state {
        case .notMeasured?: return notMeasured
        case .partial?:
            if case .some(.some(let count)) = waiting, count > 0 { return "\(partial), \(Self.waiting(count))" }
            return partial
        case .measured?: return measured
        case nil: return measured
        }
    }

    /// "Rule learning asked about your messages from 2026-09-28. Earlier weeks are not measured."
    public static func measuredFrom(_ date: String) -> String {
        "Rule learning asked about your messages from \(date). Earlier weeks are not measured."
    }

    public static let notStarted = "Rule learning has not asked about a message yet, so no week is measured."

    // MARK: A list (Table 7)

    /// The heading of a list.
    public static func listTitle(_ subject: LearningSubject) -> String {
        switch subject {
        case .repeatWeek(let week): return "Repeat corrections in the week of \(week)"
        case .violationWeek(let week): return "Violations in the week of \(week)"
        case .rulesApprovedWeek(let week): return "Rules approved in the week of \(week)"
        case .draftsToday(let day): return "Drafts written by drafting runs on \(day)"
        case .runsToday(let day): return "Drafting runs on \(day)"
        case .rulesOn: return "Rules on"
        case .group: return "The members of one group"
        case .rule: return "The violations of one rule"
        case .draft: return "The corrections behind one draft"
        case .run: return "The drafts of one drafting run"
        }
    }

    /// The short title of a list's screen.
    public static func listScreenTitle(_ subject: LearningSubject) -> String {
        switch subject.kind {
        case .repeatWeek: return "Repeat corrections"
        case .violationWeek: return "Violations"
        case .rulesApprovedWeek: return "Rules approved"
        case .draftsToday: return "Drafts"
        case .runsToday: return "Drafting runs"
        case .rulesOn: return "Rules on"
        case .group: return "Group"
        case .rule: return "Rule"
        case .draft: return "Draft"
        case .run: return "Drafting run"
        }
    }

    /// The definition at the top of a list.
    public static func listDefinition(_ subject: LearningSubject, thresholds: LearningThresholds?, cap: Int?) -> String {
        let coverage = score(thresholds?.coverage ?? defaultCoverage)
        switch subject {
        case .repeatWeek: return definition(.repeats, thresholds: thresholds, cap: cap)
        case .violationWeek: return definition(.violations, thresholds: thresholds, cap: cap)
        case .rulesApprovedWeek: return "Rules you approved in this week that you have not deleted. An imported principle counts as one rule."
        case .draftsToday: return definition(.drafts, thresholds: thresholds, cap: cap)
        case .runsToday: return definition(.runs, thresholds: thresholds, cap: cap)
        case .rulesOn: return definition(.rulesOn, thresholds: thresholds, cap: cap)
        case .group: return "Corrections that one rule may answer. The earliest one is what you said first, so it does not count as a repeat."
        case .rule: return "Messages you typed after you approved this rule that repeat it, as the model answered at \(coverage) or more."
        case .draft: return "The corrections that the drafting run read for this draft."
        case .run: return "The drafts this run wrote, whatever you decided about them."
        }
    }

    /// The exact counting rule of a list, in one sentence or two.
    public static func listRule(_ subject: LearningSubject, thresholds: LearningThresholds?) -> String {
        let coverage = score(thresholds?.coverage ?? defaultCoverage)
        switch subject.kind {
        case .repeatWeek:
            return "Rule: a correction counts from the second mention of its group on. A group the model scored under \(score(thresholds?.groupWait ?? 0.3)) does not count. Every violation counts."
        case .violationWeek, .rule:
            return "Rule: the coverage answer reads \u{201C}repeats\u{201D} at \(coverage) or more, for a message typed after the rule's approval."
        case .rulesApprovedWeek: return "Rule: the approval time lies in this week, and the rule is not deleted."
        case .draftsToday: return "Rule: a drafting run wrote the draft since midnight. Import drafts do not count."
        case .runsToday: return "Rule: the run started since midnight, whatever became of it."
        case .rulesOn: return "Rule: the rule is switched on and not deleted."
        case .group: return "Rule: two corrections of one category share their words, or the model answered that one rule answers both."
        case .draft: return "Rule: a draft keeps up to 20 corrections with their details."
        case .run: return "Rule: each draft line of the run counts once."
        }
    }

    /// The thresholds a list's scores meet.
    public static func thresholds(_ thresholds: LearningThresholds) -> String {
        "Thresholds: a message may become a correction from \(score(thresholds.kind)). A rule covers a message from \(score(thresholds.coverage)). A group is ready from \(score(thresholds.groupReady)), and splits under \(score(thresholds.groupWait))."
    }

    /// "The number: 6".
    public static func value(_ value: Int) -> String { "The number: \(value)" }
    /// "Counted at Nov 18, 2026 at 10:41".
    public static func countedAt(_ time: String) -> String { "Counted at \(time)" }
    /// "3 of 12 listed".
    public static func listed(_ shown: Int, of total: Int) -> String { "\(shown) of \(total) listed" }
    public static let showMore = "Show More"
    public static let empty = "This list is empty."

    /// The line for turns whose project cannot be read.
    public static func untraced(_ count: Int) -> String {
        count == 1 ? "1 message is left out, because its project cannot be read."
            : "\(count) messages are left out, because their project cannot be read."
    }

    /// The line for turns dated after this week.
    public static func afterThisWeek(_ count: Int) -> String {
        count == 1 ? "1 message is dated after this week, so no week counts it."
            : "\(count) messages are dated after this week, so no week counts them."
    }

    /// The line for the items a list holds without details.
    public static func older(_ count: Int, subject: LearningSubject) -> String? {
        switch subject.kind {
        case .group: return "\(count) older members, without details."
        case .rule: return "\(count) older violations, without details."
        case .draft: return "\(count) more corrections of this draft were not kept."
        default: return nil
        }
    }

    /// "Your PC counted 6 and listed 5." (Table 10).
    public static func mismatch(counted: Int, listed: Int) -> String { "Your PC counted \(counted) and listed \(listed)." }

    // MARK: What the list and the words show while they cannot (Table 11)

    public static let asking = "Asking your PC"
    public static let appearsWhileOnline = ReviewText.appearsWhileOnline
    public static let updatePC = "Update Lastide on your PC to see the list behind this number."
    public static let noAnswer = "Your PC did not answer. Try again."
    public static let tryAgain = "Try Again"
    public static let changed = "The list changed on your PC, so it reads again."
    public static let changedTooOften = "The list keeps changing on your PC. Try again in a moment."
    public static let gone = "This list is gone on your PC. Open a number again."
    public static let pagesLimited = "Enough lists for now. Try again in a minute."
    public static let blocked = "Your PC cannot read its list of excluded projects."
    public static let demoList = "Sample list. Pair a PC to see your own."

    public static let showWords = "Show My Words"
    public static let wordsFrom = "Read from your transcript, redacted"
    public static let wordsRemoved = "Words removed with the transcript"
    public static let commentRemoved = "Words removed with the comment"
    public static let rowChanged = "This row changed on your PC."
    public static let demoWords = "Pair a PC to read your words."

    /// "Enough words for now. Try again at 14:05."
    public static func wordsLimited(_ time: String) -> String { "Enough words for now. Try again at \(time)." }

    // MARK: A row's detail (Table 8)

    /// "The model's score: 0.83. A message counts from 0.40."
    public static func kindScore(_ value: Double, threshold: Double) -> String {
        "The model's score: \(score(value)). A message counts from \(score(threshold))."
    }

    /// "The model's score that the rule holds in every project: 0.61."
    public static func scopeScore(_ value: Double) -> String { "The model's score that the rule holds in every project: \(score(value))." }

    /// "The model's score that one rule prevents them: 0.88. Ready from 0.50, split under 0.30."
    public static func groupScore(_ value: Double, ready: Double, wait: Double) -> String {
        "The model's score that one rule prevents them: \(score(value)). Ready from \(score(ready)), split under \(score(wait))."
    }

    public static let groupScoreLocal = "No score: the local check grouped them"

    /// "The model's score: 0.86. A rule covers a message from 0.70."
    public static func coveredScore(_ value: Double, threshold: Double) -> String {
        "The model's score: \(score(value)). A rule covers a message from \(score(threshold))."
    }

    public static let scoreNotKept = "Score not kept"
    public static let notKept = "Not kept"
    public static let countsYes = "Yes, as a repeat correction in its week"
    public static let countsNo = "No. It is the earliest mention of its group"
    public static let countsNotRepeat = "No. It is not a repeat correction"

    /// Whether a turn counts: a repeat correction in its week, the earliest mention of its group, or neither.
    public static func counted(_ turn: LearningTurn) -> String {
        if turn.counted { return countsYes }
        return turn.group?.firstRef == turn.ref ? countsNo : countsNotRepeat
    }
    public static let modelNotKept = "Model not kept"
    public static let notEnded = "Not ended"
    public static let noTokens = "The run did not report tokens"

    /// "Repeats an approved rule" or "Repeats 2 approved rules".
    public static func violationCount(_ rules: Int) -> String {
        rules == 1 ? "Repeats an approved rule" : "Repeats \(rules) approved rules"
    }

    /// "3 members, approved".
    public static func groupLine(size: Int, state: LearningGroupState) -> String { "\(size) members, \(groupState(state))" }

    /// "Asked for claude-model-x. A terminal tab does not report tokens or a model."
    public static func terminalRun(_ model: String) -> String { "Asked for \(model). A terminal tab does not report tokens or a model." }

    /// "4,200 input, 1,800 output, 52,000 read from the cache".
    public static func tokens(_ tokens: LearningTokens) -> String {
        "\(number(tokens.input)) input, \(number(tokens.output)) output, \(number(tokens.cacheRead)) read from the cache"
    }

    /// "3,100 written to the 5-minute cache, 0 to the 1-hour cache".
    public static func cacheWrites(_ tokens: LearningTokens) -> String {
        "\(tokens.cacheWrite5m.map(number) ?? notKept) written to the 5-minute cache, \(tokens.cacheWrite1h.map(number) ?? notKept) to the 1-hour cache"
    }

    /// "$0.0980, estimated at API list prices. A run on a Claude plan does not add a bill per token."
    public static func cost(micros: Int) -> String {
        "$\(String(format: "%.4f", locale: nil, Double(micros) / 1_000_000)), estimated at API list prices. A run on a Claude plan does not add a bill per token."
    }

    /// Why a run has no cost estimate.
    public static func costMissing(_ reason: LearningCostMissing?) -> String {
        switch reason ?? .noUsage {
        case .noUsage: return "No cost estimate: the run did not report its usage."
        case .modelNotKept: return "No cost estimate: the model was not kept."
        case .noListPrice: return "No cost estimate: the model does not have a list price."
        case .cacheSplitNotKept: return "No cost estimate: the usage does not split the cache writes."
        }
    }

    /// "The run's own line says 3."
    public static func recordedDrafts(_ count: Int) -> String { "The run's own line says \(count)." }

    /// "Claude Code 2.0.0".
    public static func claudeCode(_ version: String) -> String { "Claude Code \(version)" }

    /// A whole number with group separators, the same on every phone.
    public static func number(_ value: Int) -> String {
        let digits = String(value)
        var out = ""
        for (i, character) in digits.enumerated() {
            if i > 0 && (digits.count - i) % 3 == 0 { out.append(",") }
            out.append(character)
        }
        return out
    }

    /// The name of each category, as the desktop's Agent Rules groups name it.
    public static func category(_ category: RuleGroup) -> String {
        switch category {
        case .honesty: return "Honesty"
        case .beforeActing: return "Before acting"
        case .whenStuck: return "When stuck"
        case .writing: return "Writing"
        case .documents: return "Documents"
        case .files: return "Where files go"
        case .other: return "Other"
        }
    }

    /// The state of a group, in words.
    public static func groupState(_ state: LearningGroupState) -> String {
        switch state {
        case .ready: return "ready to draft"
        case .wait: return "waiting for more corrections"
        case .split: return "split: the members need different rules"
        case .drafting: return "being drafted"
        case .drafted: return "drafted"
        case .approved: return "approved"
        case .rejected: return "rejected"
        case .deleted: return "deleted"
        case .reinforced: return "matched a rule you approved"
        case .conflict: return "against an approved rule"
        }
    }

    /// Why a correction joined its group.
    public static func join(_ join: LearningJoin?) -> String {
        switch join {
        case .lead?: return "It started the group"
        case .words?: return "It shares its words with the group"
        case .model?: return "The model answered that one rule answers both"
        case nil: return "Reason not kept"
        }
    }

    /// A rule's state, in words.
    public static func ruleState(_ state: LearningRuleState) -> String {
        switch state {
        case .on: return "On"
        case .off: return "Off"
        case .deleted: return "Deleted"
        }
    }

    /// A rule's source, in words.
    public static func ruleSource(_ source: RuleSource) -> String {
        switch source {
        case .learned: return "Learned from your corrections"
        case .imported: return "Imported from your file"
        case .builtIn: return "Built in"
        }
    }

    /// A draft's kind, in words.
    public static func draftKind(_ kind: DraftKind) -> String {
        switch kind {
        case .new: return "New rule"
        case .rewrite: return "Rewrite of a rule"
        case .merge: return "Merge"
        case .contradiction: return "Against a rule"
        case .generalize: return "Wider rule"
        case .hook: return "Hook"
        case .import: return "Import"
        case .reconfirm: return "Confirm again"
        }
    }

    /// A draft's status, in words.
    public static func draftStatus(_ status: LearningDraftStatus) -> String {
        switch status {
        case .waiting: return "Waits for your review"
        case .approved: return "Approved"
        case .rejected: return "Not a rule"
        case .deleted: return "Deleted"
        }
    }

    /// A run's route, in words.
    public static func route(_ route: LearningRoute) -> String {
        switch route {
        case .claudeCode: return "Your Claude Code"
        case .terminal: return "A terminal tab"
        case .apiKey: return "Your API key"
        }
    }

    /// A run's job, in words.
    public static func job(_ job: LearningJob) -> String { job == .draft ? "Draft rules" : "Merge imported principles" }

    /// A run's state, in words.
    public static func runState(_ state: LearningRunState) -> String {
        switch state {
        case .running: return "Runs now"
        case .finished: return "Finished"
        case .failed: return "Did not finish"
        case .lost: return "Lost: no end was recorded before a restart"
        }
    }

    /// A run's outcome, in words.
    public static func outcome(_ outcome: LearningOutcome?) -> String {
        switch outcome {
        case nil: return "Not ended"
        case .finished?: return "Finished"
        case .payingCredential?: return "Stopped: Claude Code reported a paid key"
        case .status?: return "Stopped: a limit of your plan was reached"
        case .overage?: return "Stopped: the run was using extra usage"
        case .extraUsage?: return "Stopped: extra usage is not switched off in your Claude account"
        case .anotherModel?: return "Stopped: Claude Code ran another model"
        case .unreadable?: return "Stopped: the answer did not read as drafts"
        case .hiddenText?: return "Stopped: a draft held hidden characters or a file import"
        case .cancelled?: return "Cancelled"
        case .timedOut?: return "Timed out"
        case .keyRefused?: return "Stopped: the API key was refused"
        }
    }

    /// The agent of a transcript turn, or the review comment's label.
    public static func agent(_ turn: LearningTurn) -> String {
        if let agent = turn.agent { return agent == .claudeCode ? "Claude Code" : "Codex" }
        if case .some(.some(let label)) = turn.commentLabel { return ReviewText.reviewComment(label) }
        return "Review comment, label gone"
    }
}

extension Counts {
    /// Whether this PC sends the fields of schema revision 4.
    public var hasRevisionFour: Bool { today != nil }

    /// The number on the Learning screen that a list explains, or nil when `counts` does not hold one.
    public func number(for subject: LearningSubject) -> Int? {
        switch subject {
        case .repeatWeek(let week): return weeks.first { $0.weekStart == week }?.repeatCorrections
        case .violationWeek(let week): return weeks.first { $0.weekStart == week }?.violations
        case .rulesApprovedWeek(let week): return week == weeks.last?.weekStart ? rulesApprovedThisWeek : nil
        case .draftsToday(let day): return day == today ? draftsToday : nil
        case .runsToday(let day): return day == today ? draftingRunsToday : nil
        case .rulesOn: return rulesApproved
        case .group, .rule, .draft, .run: return nil
        }
    }

    /// The bars of one chart. A PC before revision 4 sends no week states, so its weeks read as measured, and the week
    /// that holds now as partly measured.
    public func captionWeeks(_ chart: LearningChart) -> [CaptionWeek] {
        weeks.enumerated().map { index, week in
            let older: LearningSpan = index == weeks.count - 1 ? .partial : .measured
            switch chart {
            case .repeats: return CaptionWeek(weekStart: week.weekStart, value: week.repeatCorrections, state: week.repeatState ?? older)
            case .violations: return CaptionWeek(weekStart: week.weekStart, value: week.violations, state: week.violationState ?? older)
            }
        }
    }

    /// The caption under one chart, from these counts.
    public func caption(_ chart: LearningChart) -> String {
        switch chart {
        case .repeats:
            return LearningText.caption(.repeats, weeks: captionWeeks(.repeats), thisWeekSoFar: repeatCorrectionsThisWeek,
                                        lastWeekByNow: repeatCorrectionsLastWeekByNow ?? nil)
        case .violations:
            return LearningText.caption(.violations, weeks: captionWeeks(.violations), thisWeekSoFar: violationsThisWeek,
                                        lastWeekByNow: violationsLastWeekByNow ?? nil)
        }
    }
}
