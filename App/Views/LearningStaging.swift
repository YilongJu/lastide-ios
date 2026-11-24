import LastideKit
import SwiftUI

/// The learning screens of the screenshot runs (learning evidence design, check U1). The demo screens open the bundled
/// demo lists. The paired screens show WORKSTATION-A with the same lists, and never connect. Only `learningWords` shows
/// words: the one fixed synthetic sentence of the demo room, never a person's words.
enum LearningStaging {
    /// The words of the `learningWords` screen: the demo room's fixed synthetic sentence (`DEMO_WORDS` of demo-pc.mjs).
    static let stagedWords = "Synthetic demo correction for App Review."

    /// The demo lists and the demo counts.
    static func demo() -> (DemoLearning, Counts) {
        do {
            return (try DemoLearning.load(), try DemoFixtures.load().counts)
        } catch {
            preconditionFailure("the demo learning fixtures do not load: \(error)")
        }
    }

    /// The tab and the navigation path of one learning screenshot screen.
    static func path(for screen: ScreenshotScreen) -> (tab: AppTab, path: [AppRoute]) {
        let (demo, counts) = demo()
        guard let thisWeek = counts.weeks.last?.weekStart, let today = counts.today else {
            preconditionFailure("the demo counts lack the fields of revision 4")
        }
        let repeats = LearningRoute.list(.repeatWeek(weekStart: thisWeek), expected: nil)
        let turn = turnWithViolation(demo, week: thisWeek)
        func first<T>(_ subject: LearningSubject, _ pick: (LearningRow) -> T?) -> T {
            guard let value = demo.lists[subject]?.rows.lazy.compactMap(pick).first else {
                preconditionFailure("the demo list \(subject) holds no row of the kind the screenshot needs")
            }
            return value
        }
        switch screen {
        case .learningList, .learningOffline, .learningMismatch, .learningOlderPCList:
            return (.learning, [.learning(repeats)])
        case .learningTurn, .learningWords, .learningWordsLimited, .learningWordsRemoved, .learningWordsGone, .learningWordsNoAnswer:
            return (.learning, [.learning(repeats), .learning(.turn(turn))])
        case .learningGroup:
            let member = turnInGroup(demo, week: thisWeek)
            guard let group = member.group else { preconditionFailure("the demo turn joined no group") }
            return (.learning, [.learning(repeats), .learning(.turn(member)),
                                .learning(.list(.group(id: group.id), expected: group.size))])
        case .learningRule:
            let rule: LearningRule = first(.rulesOn) { row in
                if case .rule(let rule) = row, (rule.violations ?? 0) > 0 { return rule }
                return nil
            }
            return (.learning, [.learning(.list(.rulesOn, expected: nil)), .learning(.rule(rule)),
                                .learning(.list(.rule(id: rule.id), expected: rule.violations))])
        case .learningDraft:
            let draft: LearningDraft = first(.draftsToday(day: today)) { row in
                if case .draft(let draft) = row { return draft }
                return nil
            }
            return (.learning, [.learning(.list(.draftsToday(day: today), expected: nil)), .learning(.draft(draft))])
        case .learningRun:
            let run: LearningRun = first(.runsToday(day: today)) { row in
                if case .run(let run) = row, run.state == .finished { return run }
                return nil
            }
            return (.learning, [.learning(.list(.runsToday(day: today), expected: nil)), .learning(.run(run))])
        case .learningRuns:
            return (.learning, [.learning(.list(.runsToday(day: today), expected: nil))])
        case .learningWeeks, .learningPaired, .learningOlderPC:
            return (.learning, [])
        case .libraryViolations:
            let fixtures: DemoFixtures
            do { fixtures = try DemoFixtures.load() } catch { preconditionFailure("the demo fixtures do not load: \(error)") }
            guard let rule = fixtures.library.rules.first(where: { ($0.violationsSinceApproval ?? 0) > 0 }) else {
                preconditionFailure("no demo rule has a violation")
            }
            return (.library, [.rule(rule.id), .learning(.list(.rule(id: rule.id), expected: rule.violationsSinceApproval))])
        default:
            preconditionFailure("\(screen.rawValue) is not a learning screenshot screen")
        }
    }

    /// The newest turn of this week's repeat corrections that repeats an approved rule. A violation joins no group,
    /// because a covered turn stays out of the pool (learning evidence design, section 3.1).
    static func turnWithViolation(_ demo: DemoLearning, week: String) -> LearningTurn {
        let rows = demo.lists[.repeatWeek(weekStart: week)]?.rows ?? []
        for row in rows {
            if case .turn(let turn) = row, !turn.violations.isEmpty { return turn }
        }
        preconditionFailure("this week's demo list holds no turn with a violation")
    }

    /// The newest turn of this week's repeat corrections that counts through its group.
    static func turnInGroup(_ demo: DemoLearning, week: String) -> LearningTurn {
        let rows = demo.lists[.repeatWeek(weekStart: week)]?.rows ?? []
        for row in rows {
            if case .turn(let turn) = row, turn.group != nil { return turn }
        }
        preconditionFailure("this week's demo list holds no turn of a group")
    }

    /// Stages a paired screen on the screenshot model. The clock stands 2 minutes after the counts were made.
    @MainActor
    static func stage(_ screen: ScreenshotScreen, model: AppModel) throws {
        let (_, counts) = demo()
        let clock = counts.sentAt + 120_000
        model.fixClockForScreenshot(at: clock)
        func record(schema: Int) throws -> PairingRecord {
            try ScreenshotStaging.record(name: "WORKSTATION-A", firstByte: 0, lastSeenAgoMs: 120_000, pcSchema: schema)
        }
        switch screen {
        case .learningPaired:
            model.showForScreenshot(records: [try record(schema: 4)], store: try ScreenshotStaging.store(queue: true),
                                    pcOnline: true, learning: StagedLearning(online: true, words: nil))
        case .learningMismatch:
            model.showForScreenshot(records: [try record(schema: 4)], store: try ScreenshotStaging.store(queue: true),
                                    pcOnline: true, learning: StagedLearning(online: true, words: nil, valueShift: 1))
        case .learningOffline:
            model.showForScreenshot(records: [try record(schema: 4)], store: try ScreenshotStaging.store(queue: true),
                                    pcOnline: false, learning: StagedLearning(online: false, words: nil))
        case .learningWords, .learningWordsLimited, .learningWordsRemoved, .learningWordsGone, .learningWordsNoAnswer:
            let words: LearningWordsPhase
            switch screen {
            case .learningWords: words = .words(stagedWords)
            case .learningWordsLimited: words = .limited(nextAt: clock + 25 * 60_000)
            case .learningWordsRemoved: words = .removed
            case .learningWordsGone: words = .gone
            default: words = .noAnswer
            }
            model.showForScreenshot(records: [try record(schema: 4)], store: try ScreenshotStaging.store(queue: true),
                                    pcOnline: true, learning: StagedLearning(online: true, words: words))
        case .learningOlderPC, .learningOlderPCList:
            // A PC of revision 3 sends `counts` without the fields of revision 4.
            var store = try ScreenshotStaging.store(queue: true)
            var old = counts
            old.schema = 3
            old.rulesApprovedThisWeek = nil
            old.repeatCorrectionsLastWeekByNow = nil
            old.violationsLastWeekByNow = nil
            old.draftingRunsFinishedToday = nil
            old.measuredFrom = nil
            old.today = nil
            for index in old.weeks.indices {
                old.weeks[index].repeatState = nil
                old.weeks[index].violationState = nil
                old.weeks[index].waiting = nil
                old.weeks[index].untraced = nil
            }
            store.apply(.counts(old))
            model.showForScreenshot(records: [try record(schema: 3)], store: store, pcOnline: true,
                                    learning: StagedLearning(online: true, words: nil))
        default:
            preconditionFailure("\(screen.rawValue) is not a paired learning screenshot screen")
        }
    }
}
