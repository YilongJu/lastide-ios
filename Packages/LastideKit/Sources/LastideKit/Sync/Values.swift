import Foundation

/// The coding agent a rule or a correction belongs to.
public enum Agent: String, Codable, Sendable, CaseIterable { case claudeCode, codex }

/// How the PC arrived at a draft.
public enum DraftKind: String, Codable, Sendable, CaseIterable {
    case new, rewrite, merge, contradiction, generalize, hook, `import`, reconfirm
}

/// The group a draft or a rule sits in.
public enum RuleGroup: String, Codable, Sendable, CaseIterable {
    case honesty, beforeActing, whenStuck, writing, documents, files, other
}

/// Whether a rule states a preference or a hard limit.
public enum Strength: String, Codable, Sendable, CaseIterable { case preference, hardLimit }

/// The kind of signal behind one evidence item.
public enum Signal: String, Codable, Sendable, CaseIterable {
    case typedTurn, midTurnMessage, afterInterrupt, refusalComment, rewind, reviewComment
    case quoteReply, fileEdit, instructionFileEdit, agentInstructionFileWrite, promptHistory
}

/// Where a rule applies.
public enum ScopeKind: String, Codable, Sendable, CaseIterable { case thisProject, kindOfWork, everyProject }

/// Where an approved rule came from.
public enum RuleSource: String, Codable, Sendable, CaseIterable { case learned, imported, builtIn }

/// Whether an approved rule is on.
public enum RuleState: String, Codable, Sendable, CaseIterable { case on, off, escalated }

/// The device of a rule's last edit.
public enum EditedOn: String, Codable, Sendable, CaseIterable { case desktop, phone }

/// A relay feature that `pair-accept` lists.
public enum Feature: String, Codable, Sendable, CaseIterable { case mailbox, push }

/// What the PC sent for one evidence item.
public enum EvidenceState: String, Codable, Sendable, CaseIterable { case words, removed, excluded }

/// What the phone may do to a draft or a rule (Table 21).
public enum DecisionAction: String, Codable, Sendable, CaseIterable {
    case approve, saveEdit, reject, delete, edit, turnOff, turnOn

    /// Whether this action fits a target of the given type.
    public func fits(_ targetType: TargetType) -> Bool {
        switch self {
        case .approve, .saveEdit, .reject: return targetType == .draft
        case .edit, .turnOff, .turnOn: return targetType == .rule
        case .delete: return true
        }
    }
}

/// Whether a decision acts on a draft or a rule.
public enum TargetType: String, Codable, Sendable, CaseIterable { case draft, rule }

/// The code of an `error` message (Table 12).
public enum ErrorCode: String, Codable, Sendable, CaseIterable { case badMessage, unknownType }

/// Whether the PC applied a decision.
public enum AcknowledgementResult: String, Codable, Sendable, CaseIterable { case applied, refused }

/// Why the PC refused a decision, with the sentence the phone shows (Table 22).
public enum RefusalReason: String, Codable, Sendable, CaseIterable {
    case expired, gone, desktopOnly, staleVersion, invalidAction, invalidText, invalidScope

    /// The fixed sentence of Table 22. Only `desktopOnly` reads differently for a draft and a rule.
    public func displayText(for targetType: TargetType) -> String {
        switch self {
        case .expired: return "This change waited too long. Make it again."
        case .gone: return "Your PC already handled this one."
        case .desktopOnly: return targetType == .draft ? "Approve this one on your PC" : "Change this one on your PC"
        case .staleVersion: return "Your PC changed this one. Review the new version."
        case .invalidAction: return "Your PC could not apply this change."
        case .invalidText: return "Your PC could not use this text."
        case .invalidScope: return "Your PC could not use this scope."
        }
    }
}

/// Why the PC ended a pairing, with the sentence the phone shows (Table 7).
public enum PairRefuseReason: String, Codable, Sendable, CaseIterable {
    case wrongCode, expired, twoPhones, cancelled, tooManyPhones

    /// The fixed sentence of Table 7.
    public var displayText: String {
        switch self {
        case .wrongCode: return "The code did not match. Pairing stopped."
        case .expired: return "Pairing timed out. Scan a new code."
        case .twoPhones: return "Pairing stopped. Show a new code on your PC."
        case .cancelled: return "Pairing was cancelled on your PC."
        case .tooManyPhones: return "This PC has 8 phones. Remove one on the PC first."
        }
    }
}
