import LastideKit
import SwiftUI
import UIKit

enum AppTab: Hashable {
    case review, library, learning, settings
}

/// The four tabs: Review (the queue and the rule detail), Library, Learning and Settings (protocol Table 23).
struct RootView: View {
    @Bindable var model: AppModel
    @State private var tab: AppTab
    @State private var queuePath: [String]
    @State private var libraryPath: [AppRoute]
    @State private var learningPath: [AppRoute]

    init(model: AppModel, screenshot: ScreenshotScreen?) {
        _model = Bindable(wrappedValue: model)
        var tab = AppTab.review
        var queuePath: [String] = []
        var libraryPath: [AppRoute] = []
        var learningPath: [AppRoute] = []
        switch screenshot {
        case .none, .queue, .queueWaiting, .queueEmpty: break
        case .draftDetail:
            guard let draft = model.store.drafts.first(where: { !$0.desktopOnly }) else {
                preconditionFailure("the demo queue holds no draft that the phone may act on")
            }
            queuePath = [draft.id]
        case .library, .libraryNotMeasured: tab = .library
        case .ruleDetail:
            tab = .library
            guard let rule = model.store.rules.first else { preconditionFailure("the demo library holds no rule") }
            libraryPath = [.rule(rule.id)]
        case .learning, .learningNotMeasured: tab = .learning
        case .learningList, .learningTurn, .learningGroup, .learningRule, .learningDraft, .learningRun, .learningRuns,
             .learningWeeks, .learningPaired, .learningOffline, .learningOlderPC, .learningOlderPCList, .learningMismatch,
             .learningWords, .learningWordsLimited, .learningWordsRemoved, .learningWordsGone, .learningWordsNoAnswer, .libraryViolations:
            let staged = LearningStaging.path(for: screenshot!)
            tab = staged.tab
            if staged.tab == .library { libraryPath = staged.path } else { learningPath = staged.path }
        case .settings, .settingsPaired, .pairingDisclosure, .pairingScan, .pairingWaiting, .pairingCode, .pairingFailed,
             .settingsNotificationsOn, .settingsNotificationsOff:
            tab = .settings
        case .widgetSmall, .widgetRectangular:
            preconditionFailure("the widget screens draw WidgetScreenshotView, not the tabs")
        }
        _tab = State(initialValue: tab)
        _queuePath = State(initialValue: queuePath)
        _libraryPath = State(initialValue: libraryPath)
        _learningPath = State(initialValue: learningPath)
    }

    var body: some View {
        if let launchError = model.launchError {
            LaunchErrorView(model: model, text: launchError)
        } else {
            tabs
                .alert(PushText.permissionQuestion, isPresented: $model.askNotifications) {
                    Button(AppText.turnOn) { Task { await model.answerNotificationQuestion(turnOn: true) } }
                    Button(AppText.notNow, role: .cancel) { Task { await model.answerNotificationQuestion(turnOn: false) } }
                }
        }
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            Tab("Review", systemImage: "tray.full", value: AppTab.review) {
                QueueView(model: model, path: $queuePath, onPair: { tab = .settings })
            }
            .badge(model.store.badgeCount)
            Tab("Library", systemImage: "books.vertical", value: AppTab.library) {
                LibraryView(model: model, path: $libraryPath, onPair: { tab = .settings })
            }
            Tab("Learning", systemImage: "chart.bar", value: AppTab.learning) {
                LearningView(model: model, path: $learningPath, onPair: { tab = .settings })
            }
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                SettingsView(model: model)
            }
        }
        .alert("Lastide", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.notice ?? "")
        }
        // A list lives while its screen is on a navigation stack (protocol 7.6).
        .onChange(of: libraryPath + learningPath) { _, routes in
            model.keepLists(Set(routes.compactMap { route in
                if case .learning(let learning) = route { return learning.subject }
                return nil
            }))
        }
    }
}

/// The launch error of design section 6.2, such as a missing App Group container, with the diagnostics block.
/// The app stops here before it reads another file or deletes a Keychain item.
struct LaunchErrorView: View {
    @Bindable var model: AppModel
    let text: String

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(text, systemImage: "exclamationmark.triangle")
                        .accessibilityIdentifier("launchError")
                }
                Section {
                    Text(diagnosticsText)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                } footer: {
                    Text("Copy this block into a support message.")
                }
                Section {
                    Button("Copy") { UIPasteboard.general.string = diagnosticsText }
                }
            }
            .navigationTitle("Lastide")
        }
    }

    private var diagnosticsText: String {
        model.diagnostics.text(build: model.facts.app, pairingState: "stopped at launch", relayOrigin: nil,
                               push: model.pushFacts)
    }
}

/// Words the screens share.
enum Words {
    static func scope(_ scope: Scope) -> String {
        switch scope.kind {
        case .everyProject: return "All projects"
        case .thisProject: return scope.projectNames.joined(separator: ", ")
        case .kindOfWork: return "Kind of work: " + (scope.kindOfWork ?? "")
        }
    }

    /// "3 corrections · 1 violation since approval", or "3 corrections · Violations: Not measured yet" while the PC sends
    /// the count as null (protocol 7.3).
    static func counters(_ rule: Rule) -> String {
        let corrections = rule.correctionsBeforeApproval == 1 ? "1 correction" : "\(rule.correctionsBeforeApproval) corrections"
        let violations: String
        switch rule.violationsSinceApproval {
        case nil: violations = "Violations: " + ReviewText.notMeasured
        case 1?: violations = "1 violation since approval"
        case let count?: violations = "\(count) violations since approval"
        }
        return corrections + " · " + violations
    }

    /// A count as a number, or "Not measured yet" when the PC sends it as null (protocol 7.3).
    static func count(_ value: Int?) -> String { value.map { "\($0)" } ?? ReviewText.notMeasured }

    static func agents(_ agents: [Agent]) -> String {
        agents.map { $0 == .claudeCode ? "Claude Code" : "Codex" }.joined(separator: ", ")
    }

    /// The agent of an evidence row, or "Review comment C7" where a review comment has no agent (protocol 7.3).
    static func source(_ item: EvidenceItem) -> String {
        if let agent = item.agent { return agents([agent]) }
        return ReviewText.reviewComment(item.commentLabel ?? "")
    }

    static func signal(_ signal: Signal) -> String {
        switch signal {
        case .typedTurn: return "Typed message"
        case .midTurnMessage: return "Message during a turn"
        case .afterInterrupt: return "After an interrupt"
        case .refusalComment: return "Comment on a refusal"
        case .rewind: return "Rewind"
        case .reviewComment: return "Review comment"
        case .quoteReply: return "Quoted reply"
        case .fileEdit: return "File edit"
        case .instructionFileEdit: return "Instruction file edit"
        case .agentInstructionFileWrite: return "Agent wrote an instruction file"
        case .promptHistory: return "Prompt history"
        }
    }

    static func group(_ group: RuleGroup) -> String {
        switch group {
        case .honesty: return "Honesty"
        case .beforeActing: return "Before acting"
        case .whenStuck: return "When stuck"
        case .writing: return "Writing"
        case .documents: return "Documents"
        case .files: return "Files"
        case .other: return "Other"
        }
    }

    /// A protocol time as a short date, for example "Nov 18, 2026".
    static func date(_ time: Int) -> String {
        Date(timeIntervalSince1970: Double(time) / 1_000).formatted(date: .abbreviated, time: .omitted)
    }

    /// The scope option whose scope equals the item's own scope (protocol section 7.3, field notes).
    static func currentOptionID(_ scope: Scope, _ options: [ScopeOption]) -> String? {
        options.first { $0.scope == scope }?.id
    }

    /// The phone sends one line: a line break typed into the editor becomes a space.
    static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}
