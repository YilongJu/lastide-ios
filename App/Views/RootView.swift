import LastideKit
import SwiftUI

enum AppTab: Hashable {
    case review, library, learning, settings
}

/// The four tabs: Review (the queue and the rule detail), Library, Learning and Settings (protocol Table 23).
struct RootView: View {
    @Bindable var model: AppModel
    @State private var tab: AppTab
    @State private var queuePath: [String]
    @State private var libraryPath: [String]

    init(model: AppModel, screenshot: ScreenshotScreen?) {
        _model = Bindable(wrappedValue: model)
        var tab = AppTab.review
        var queuePath: [String] = []
        var libraryPath: [String] = []
        switch screenshot {
        case .none, .queue, .queueWaiting, .queueEmpty: break
        case .draftDetail:
            guard let draft = model.store.drafts.first(where: { !$0.desktopOnly }) else {
                preconditionFailure("the demo queue holds no draft that the phone may act on")
            }
            queuePath = [draft.id]
        case .library: tab = .library
        case .ruleDetail:
            tab = .library
            guard let rule = model.store.rules.first else { preconditionFailure("the demo library holds no rule") }
            libraryPath = [rule.id]
        case .learning: tab = .learning
        case .settings, .settingsPaired, .pairingDisclosure, .pairingScan, .pairingWaiting, .pairingCode, .pairingFailed:
            tab = .settings
        }
        _tab = State(initialValue: tab)
        _queuePath = State(initialValue: queuePath)
        _libraryPath = State(initialValue: libraryPath)
    }

    var body: some View {
        TabView(selection: $tab) {
            Tab("Review", systemImage: "tray.full", value: AppTab.review) {
                QueueView(model: model, path: $queuePath, onPair: { tab = .settings })
            }
            .badge(model.store.badgeCount)
            Tab("Library", systemImage: "books.vertical", value: AppTab.library) {
                LibraryView(model: model, path: $libraryPath, onPair: { tab = .settings })
            }
            Tab("Learning", systemImage: "chart.bar", value: AppTab.learning) {
                LearningView(model: model, onPair: { tab = .settings })
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

    /// "3 corrections · 1 violation since approval".
    static func counters(_ rule: Rule) -> String {
        let corrections = rule.correctionsBeforeApproval == 1 ? "1 correction" : "\(rule.correctionsBeforeApproval) corrections"
        let violations = rule.violationsSinceApproval == 1
            ? "1 violation since approval" : "\(rule.violationsSinceApproval) violations since approval"
        return corrections + " · " + violations
    }

    static func agents(_ agents: [Agent]) -> String {
        agents.map { $0 == .claudeCode ? "Claude Code" : "Codex" }.joined(separator: ", ")
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
