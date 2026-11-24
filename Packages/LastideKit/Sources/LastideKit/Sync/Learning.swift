import Foundation

// The learning lists and words of schema revision 4 (protocol section 7.6, the `learning*` definitions of section 7.3).
// Each number of the Learning screen is the length of a list on the PC. A row never holds a path, a session id or the
// person's words.

/// Whether a week of `counts.weeks` was measured (protocol 7.3, `learningSpan`).
public enum LearningSpan: String, Codable, Sendable, CaseIterable { case measured, partial, notMeasured }

/// The state of a group of corrections (`groupState`).
public enum LearningGroupState: String, Codable, Sendable, CaseIterable {
    case ready, wait, split, drafting, drafted, approved, rejected, deleted, reinforced, conflict
}

/// Why a correction joined its group: it started the group, it shares its words, or the model said one rule answers both.
public enum LearningJoin: String, Codable, Sendable, CaseIterable { case lead, words, model }

/// A rule's state in a learning row. A deleted rule's violations still count.
public enum LearningRuleState: String, Codable, Sendable, CaseIterable { case on, off, deleted }

/// A draft's status in a learning row.
public enum LearningDraftStatus: String, Codable, Sendable, CaseIterable { case waiting, approved, rejected, deleted }

/// How a drafting run reached Claude Code.
public enum LearningRoute: String, Codable, Sendable, CaseIterable { case claudeCode, terminal, apiKey }

/// What a drafting run did.
public enum LearningJob: String, Codable, Sendable, CaseIterable { case draft, importMerge }

/// Whether a drafting run ended.
public enum LearningRunState: String, Codable, Sendable, CaseIterable { case running, finished, failed, lost }

/// How a drafting run ended.
public enum LearningOutcome: String, Codable, Sendable, CaseIterable {
    case finished, payingCredential, status, overage, extraUsage, anotherModel, unreadable, hiddenText, cancelled
    case timedOut, keyRefused
}

/// Why a run has no cost estimate.
public enum LearningCostMissing: String, Codable, Sendable, CaseIterable { case modelNotKept, noListPrice, cacheSplitNotKept, noUsage }

/// The PC's answer to one `learning-request`.
public enum LearningPageState: String, Codable, Sendable, CaseIterable { case ok, changed, gone, limited, blocked }

/// The PC's answer to one `learning-words-request`.
public enum LearningWordsState: String, Codable, Sendable, CaseIterable { case words, removed, gone, limited }

/// The `subject.kind` of a learning list (protocol Table 31).
public enum LearningSubjectKind: String, Codable, Sendable, CaseIterable {
    case repeatWeek, violationWeek, rulesApprovedWeek, draftsToday, runsToday, rulesOn, group, rule, draft, run
}

/// The list one number explains (protocol Table 31). Each kind carries only its own field.
public enum LearningSubject: Hashable, Sendable, Codable, Validatable {
    case repeatWeek(weekStart: String)
    case violationWeek(weekStart: String)
    case rulesApprovedWeek(weekStart: String)
    case draftsToday(day: String)
    case runsToday(day: String)
    case rulesOn
    case group(id: String)
    case rule(id: String)
    case draft(id: String)
    case run(id: String)

    /// The subject's `kind`.
    public var kind: LearningSubjectKind {
        switch self {
        case .repeatWeek: return .repeatWeek
        case .violationWeek: return .violationWeek
        case .rulesApprovedWeek: return .rulesApprovedWeek
        case .draftsToday: return .draftsToday
        case .runsToday: return .runsToday
        case .rulesOn: return .rulesOn
        case .group: return .group
        case .rule: return .rule
        case .draft: return .draft
        case .run: return .run
        }
    }

    enum CodingKeys: String, CodingKey { case kind, weekStart, day, id }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // The receiver reads only the fields of the kind and ignores any other (protocol 6.3, 7.1).
        switch try c.decode(LearningSubjectKind.self, forKey: .kind) {
        case .repeatWeek: self = .repeatWeek(weekStart: try c.decode(String.self, forKey: .weekStart))
        case .violationWeek: self = .violationWeek(weekStart: try c.decode(String.self, forKey: .weekStart))
        case .rulesApprovedWeek: self = .rulesApprovedWeek(weekStart: try c.decode(String.self, forKey: .weekStart))
        case .draftsToday: self = .draftsToday(day: try c.decode(String.self, forKey: .day))
        case .runsToday: self = .runsToday(day: try c.decode(String.self, forKey: .day))
        case .rulesOn: self = .rulesOn
        case .group: self = .group(id: try c.decode(String.self, forKey: .id))
        case .rule: self = .rule(id: try c.decode(String.self, forKey: .id))
        case .draft: self = .draft(id: try c.decode(String.self, forKey: .id))
        case .run: self = .run(id: try c.decode(String.self, forKey: .id))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        switch self {
        case .repeatWeek(let weekStart), .violationWeek(let weekStart), .rulesApprovedWeek(let weekStart):
            try c.encode(weekStart, forKey: .weekStart)
        case .draftsToday(let day), .runsToday(let day):
            try c.encode(day, forKey: .day)
        case .rulesOn:
            break
        case .group(let id), .rule(let id), .draft(let id), .run(let id):
            try c.encode(id, forKey: .id)
        }
    }

    func validate(_ path: String) throws {
        switch self {
        case .repeatWeek(let weekStart), .violationWeek(let weekStart), .rulesApprovedWeek(let weekStart):
            try Check.weekStart(weekStart, path + ".weekStart")
        case .draftsToday(let day), .runsToday(let day):
            try Check.weekStart(day, path + ".day")
        case .rulesOn:
            break
        case .group(let id), .rule(let id), .draft(let id), .run(let id):
            try Check.itemID(id, path + ".id")
        }
    }
}

/// The group a turn joined, as a turn row names it (`learningGroupRef`).
public struct LearningGroupRef: Hashable, Sendable, Codable, Validatable {
    public var id: String
    public var size: Int
    public var state: LearningGroupState
    /// The model's score that one rule prevents the members, or null for a group of the local check.
    public var oneRulePrevents: Double?
    public var joinedBy: LearningJoin?
    /// The earliest member, which does not count.
    public var firstRef: String?
    public var firstAt: Int?
    public var draftId: String?
    public var ruleId: String?

    enum CodingKeys: String, CodingKey { case id, size, state, oneRulePrevents, joinedBy, firstRef, firstAt, draftId, ruleId }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        size = try c.decode(Int.self, forKey: .size)
        state = try c.decode(LearningGroupState.self, forKey: .state)
        oneRulePrevents = try c.nullable(Double.self, forKey: .oneRulePrevents)
        joinedBy = try c.nullable(LearningJoin.self, forKey: .joinedBy)
        firstRef = try c.nullable(String.self, forKey: .firstRef)
        firstAt = try c.nullable(Int.self, forKey: .firstAt)
        draftId = try c.nullable(String.self, forKey: .draftId)
        ruleId = try c.nullable(String.self, forKey: .ruleId)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(size, forKey: .size)
        try c.encode(state, forKey: .state)
        try c.encodeNullable(oneRulePrevents, forKey: .oneRulePrevents)
        try c.encodeNullable(joinedBy, forKey: .joinedBy)
        try c.encodeNullable(firstRef, forKey: .firstRef)
        try c.encodeNullable(firstAt, forKey: .firstAt)
        try c.encodeNullable(draftId, forKey: .draftId)
        try c.encodeNullable(ruleId, forKey: .ruleId)
    }

    func validate(_ path: String) throws {
        try Check.itemID(id, path + ".id")
        try Check.integer(size, path + ".size")
        try Check.optionalProbability(oneRulePrevents, path + ".oneRulePrevents")
        if let firstRef { try Check.learningRef(firstRef, path + ".firstRef") }
        try Check.optionalInteger(firstAt, path + ".firstAt")
        if let draftId { try Check.itemID(draftId, path + ".draftId") }
        if let ruleId { try Check.itemID(ruleId, path + ".ruleId") }
    }
}

/// One approved rule that a turn repeats (`learningViolation`).
public struct LearningViolation: Hashable, Sendable, Codable, Validatable {
    public var ruleId: String
    public var ruleText: String
    public var textCut: Bool
    public var ruleState: LearningRuleState
    public var ruleApprovedAt: Int
    /// The coverage score, or null when an older line did not keep it.
    public var covered: Double?
    /// The probability of the relation `repeats`, or null when an older line did not keep it.
    public var repeats: Double?
    public var contradicts: Double
    public var answeredAt: Int

    enum CodingKeys: String, CodingKey {
        case ruleId, ruleText, textCut, ruleState, ruleApprovedAt, covered, repeats, contradicts, answeredAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ruleId = try c.decode(String.self, forKey: .ruleId)
        ruleText = try c.decode(String.self, forKey: .ruleText)
        textCut = try c.decode(Bool.self, forKey: .textCut)
        ruleState = try c.decode(LearningRuleState.self, forKey: .ruleState)
        ruleApprovedAt = try c.decode(Int.self, forKey: .ruleApprovedAt)
        covered = try c.nullable(Double.self, forKey: .covered)
        repeats = try c.nullable(Double.self, forKey: .repeats)
        contradicts = try c.decode(Double.self, forKey: .contradicts)
        answeredAt = try c.decode(Int.self, forKey: .answeredAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ruleId, forKey: .ruleId)
        try c.encode(ruleText, forKey: .ruleText)
        try c.encode(textCut, forKey: .textCut)
        try c.encode(ruleState, forKey: .ruleState)
        try c.encode(ruleApprovedAt, forKey: .ruleApprovedAt)
        try c.encodeNullable(covered, forKey: .covered)
        try c.encodeNullable(repeats, forKey: .repeats)
        try c.encode(contradicts, forKey: .contradicts)
        try c.encode(answeredAt, forKey: .answeredAt)
    }

    func validate(_ path: String) throws {
        try Check.itemID(ruleId, path + ".ruleId")
        try Check.learningText(ruleText, path + ".ruleText")
        try Check.integer(ruleApprovedAt, path + ".ruleApprovedAt")
        try Check.optionalProbability(covered, path + ".covered")
        try Check.optionalProbability(repeats, path + ".repeats")
        try Check.probability(contradicts, path + ".contradicts")
        try Check.integer(answeredAt, path + ".answeredAt")
    }
}

/// One message the person typed, or one review comment, as a list row (`learningTurn`). It never holds the words.
public struct LearningTurn: Hashable, Sendable, Codable, Validatable {
    /// The opaque turn reference that Show My Words sends.
    public var ref: String
    public var at: Int
    public var projectName: String
    /// Null for a review comment.
    public var agent: Agent?
    /// The review comment's label: absent for a transcript turn, null when the label is gone.
    public var commentLabel: String??
    /// Null when the store did not keep the signal.
    public var signal: Signal?
    public var category: RuleGroup?
    public var kindScore: Double?
    public var scopeScore: Double?
    public var questionVersion: Int?
    /// False only for the earliest member of a group, in the subject `group`, and for a draft's turn that counts in no week.
    public var counted: Bool
    public var countedAt: Int?
    public var group: LearningGroupRef?
    public var violations: [LearningViolation]

    enum CodingKeys: String, CodingKey {
        case rowType, ref, at, projectName, agent, commentLabel, signal, category, kindScore, scopeScore, questionVersion
        case counted, countedAt, group, violations
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(String.self, forKey: .rowType) == "turn" else {
            throw DecodingError.dataCorruptedError(forKey: .rowType, in: c, debugDescription: "rowType is not turn")
        }
        ref = try c.decode(String.self, forKey: .ref)
        at = try c.decode(Int.self, forKey: .at)
        projectName = try c.decode(String.self, forKey: .projectName)
        agent = try c.nullable(Agent.self, forKey: .agent)
        commentLabel = try c.optionalNullable(String.self, forKey: .commentLabel)
        signal = try c.nullable(Signal.self, forKey: .signal)
        category = try c.nullable(RuleGroup.self, forKey: .category)
        kindScore = try c.nullable(Double.self, forKey: .kindScore)
        scopeScore = try c.nullable(Double.self, forKey: .scopeScore)
        questionVersion = try c.nullable(Int.self, forKey: .questionVersion)
        counted = try c.decode(Bool.self, forKey: .counted)
        countedAt = try c.nullable(Int.self, forKey: .countedAt)
        group = try c.nullable(LearningGroupRef.self, forKey: .group)
        violations = try c.decode([LearningViolation].self, forKey: .violations)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("turn", forKey: .rowType)
        try c.encode(ref, forKey: .ref)
        try c.encode(at, forKey: .at)
        try c.encode(projectName, forKey: .projectName)
        try c.encodeNullable(agent, forKey: .agent)
        try c.encodeOptionalNullable(commentLabel, forKey: .commentLabel)
        try c.encodeNullable(signal, forKey: .signal)
        try c.encodeNullable(category, forKey: .category)
        try c.encodeNullable(kindScore, forKey: .kindScore)
        try c.encodeNullable(scopeScore, forKey: .scopeScore)
        try c.encodeNullable(questionVersion, forKey: .questionVersion)
        try c.encode(counted, forKey: .counted)
        try c.encodeNullable(countedAt, forKey: .countedAt)
        try c.encodeNullable(group, forKey: .group)
        try c.encode(violations, forKey: .violations)
    }

    func validate(_ path: String) throws {
        try Check.learningRef(ref, path + ".ref")
        try Check.integer(at, path + ".at")
        try Check.text(projectName, path + ".projectName", minimum: 1, maximum: 128)
        if case .some(.some(let label)) = commentLabel { try Check.commentLabel(label, path + ".commentLabel") }
        try Check.optionalProbability(kindScore, path + ".kindScore")
        try Check.optionalProbability(scopeScore, path + ".scopeScore")
        try Check.optionalInteger(questionVersion, path + ".questionVersion")
        try Check.optionalInteger(countedAt, path + ".countedAt")
        try group?.validate(path + ".group")
        try Check.count(violations, path + ".violations", minimum: 0, maximum: 8)
        for (i, violation) in violations.enumerated() { try violation.validate(path + ".violations[\(i)]") }
        if agent == nil {
            try Check.that(commentLabel != nil, path + ".commentLabel", "present when agent is null")
            try Check.that(signal == nil || signal == .reviewComment, path + ".signal", "reviewComment or null when agent is null")
        }
    }
}

/// One approved rule as a list row or a list's head (`learningRule`).
public struct LearningRule: Hashable, Sendable, Codable, Validatable {
    public var id: String
    public var text: String
    public var textCut: Bool
    public var state: LearningRuleState
    public var source: RuleSource
    public var category: RuleGroup
    public var scope: Scope
    public var approvedAt: Int
    public var correctionsBeforeApproval: Int
    public var violations: Int?
    public var draftId: String?
    public var runId: String?

    enum CodingKeys: String, CodingKey {
        case rowType, id, text, textCut, state, source, category, scope, approvedAt, correctionsBeforeApproval, violations
        case draftId, runId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(String.self, forKey: .rowType) == "rule" else {
            throw DecodingError.dataCorruptedError(forKey: .rowType, in: c, debugDescription: "rowType is not rule")
        }
        id = try c.decode(String.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        textCut = try c.decode(Bool.self, forKey: .textCut)
        state = try c.decode(LearningRuleState.self, forKey: .state)
        source = try c.decode(RuleSource.self, forKey: .source)
        category = try c.decode(RuleGroup.self, forKey: .category)
        scope = try c.decode(Scope.self, forKey: .scope)
        approvedAt = try c.decode(Int.self, forKey: .approvedAt)
        correctionsBeforeApproval = try c.decode(Int.self, forKey: .correctionsBeforeApproval)
        violations = try c.nullable(Int.self, forKey: .violations)
        draftId = try c.nullable(String.self, forKey: .draftId)
        runId = try c.nullable(String.self, forKey: .runId)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("rule", forKey: .rowType)
        try c.encode(id, forKey: .id)
        try c.encode(text, forKey: .text)
        try c.encode(textCut, forKey: .textCut)
        try c.encode(state, forKey: .state)
        try c.encode(source, forKey: .source)
        try c.encode(category, forKey: .category)
        try c.encode(scope, forKey: .scope)
        try c.encode(approvedAt, forKey: .approvedAt)
        try c.encode(correctionsBeforeApproval, forKey: .correctionsBeforeApproval)
        try c.encodeNullable(violations, forKey: .violations)
        try c.encodeNullable(draftId, forKey: .draftId)
        try c.encodeNullable(runId, forKey: .runId)
    }

    func validate(_ path: String) throws {
        try Check.itemID(id, path + ".id")
        try Check.learningText(text, path + ".text")
        try scope.validate(path + ".scope")
        try Check.integer(approvedAt, path + ".approvedAt")
        try Check.integer(correctionsBeforeApproval, path + ".correctionsBeforeApproval")
        try Check.optionalInteger(violations, path + ".violations")
        if let draftId { try Check.itemID(draftId, path + ".draftId") }
        if let runId { try Check.itemID(runId, path + ".runId") }
    }
}

/// One draft as a list row or a list's head (`learningDraft`).
public struct LearningDraft: Hashable, Sendable, Codable, Validatable {
    public var id: String
    public var draftKind: DraftKind
    public var status: LearningDraftStatus
    /// Null for a merge draft of an import batch, because an import never travels.
    public var text: String?
    public var textCut: Bool
    public var createdAt: Int
    public var category: RuleGroup
    public var evidenceCount: Int
    public var groupId: String?
    public var runId: String?

    enum CodingKeys: String, CodingKey {
        case rowType, id, draftKind, status, text, textCut, createdAt, category, evidenceCount, groupId, runId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(String.self, forKey: .rowType) == "draft" else {
            throw DecodingError.dataCorruptedError(forKey: .rowType, in: c, debugDescription: "rowType is not draft")
        }
        id = try c.decode(String.self, forKey: .id)
        draftKind = try c.decode(DraftKind.self, forKey: .draftKind)
        status = try c.decode(LearningDraftStatus.self, forKey: .status)
        text = try c.nullable(String.self, forKey: .text)
        textCut = try c.decode(Bool.self, forKey: .textCut)
        createdAt = try c.decode(Int.self, forKey: .createdAt)
        category = try c.decode(RuleGroup.self, forKey: .category)
        evidenceCount = try c.decode(Int.self, forKey: .evidenceCount)
        groupId = try c.nullable(String.self, forKey: .groupId)
        runId = try c.nullable(String.self, forKey: .runId)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("draft", forKey: .rowType)
        try c.encode(id, forKey: .id)
        try c.encode(draftKind, forKey: .draftKind)
        try c.encode(status, forKey: .status)
        try c.encodeNullable(text, forKey: .text)
        try c.encode(textCut, forKey: .textCut)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(category, forKey: .category)
        try c.encode(evidenceCount, forKey: .evidenceCount)
        try c.encodeNullable(groupId, forKey: .groupId)
        try c.encodeNullable(runId, forKey: .runId)
    }

    func validate(_ path: String) throws {
        try Check.itemID(id, path + ".id")
        if let text { try Check.learningText(text, path + ".text") }
        try Check.integer(createdAt, path + ".createdAt")
        try Check.integer(evidenceCount, path + ".evidenceCount")
        if let groupId { try Check.itemID(groupId, path + ".groupId") }
        if let runId { try Check.itemID(runId, path + ".runId") }
    }
}

/// The tokens a drafting run reported (`learningTokens`).
public struct LearningTokens: Hashable, Sendable, Codable, Validatable {
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    /// Null when the usage did not split the cache writes.
    public var cacheWrite5m: Int?
    public var cacheWrite1h: Int?

    enum CodingKeys: String, CodingKey { case input, output, cacheRead, cacheWrite5m, cacheWrite1h }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        input = try c.decode(Int.self, forKey: .input)
        output = try c.decode(Int.self, forKey: .output)
        cacheRead = try c.decode(Int.self, forKey: .cacheRead)
        cacheWrite5m = try c.nullable(Int.self, forKey: .cacheWrite5m)
        cacheWrite1h = try c.nullable(Int.self, forKey: .cacheWrite1h)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(input, forKey: .input)
        try c.encode(output, forKey: .output)
        try c.encode(cacheRead, forKey: .cacheRead)
        try c.encodeNullable(cacheWrite5m, forKey: .cacheWrite5m)
        try c.encodeNullable(cacheWrite1h, forKey: .cacheWrite1h)
    }

    func validate(_ path: String) throws {
        for (value, name) in [(input, "input"), (output, "output"), (cacheRead, "cacheRead")] {
            try Check.integer(value, path + "." + name)
        }
        try Check.optionalInteger(cacheWrite5m, path + ".cacheWrite5m")
        try Check.optionalInteger(cacheWrite1h, path + ".cacheWrite1h")
    }
}

/// One drafting run as a list row or a list's head (`learningRun`).
public struct LearningRun: Hashable, Sendable, Codable, Validatable {
    public var id: String
    public var route: LearningRoute
    public var job: LearningJob
    public var state: LearningRunState
    public var outcome: LearningOutcome?
    public var startedAt: Int
    public var endedAt: Int?
    /// The Claude Code version, or null when the run did not report it.
    public var version: String?
    public var requestedModel: String?
    public var reportedModel: String?
    public var tokens: LearningTokens?
    /// Millionths of a dollar at API list prices, or null with `costMissing`.
    public var costMicros: Int?
    public var costMissing: LearningCostMissing?
    public var groups: Int
    public var drafts: Int
    /// The run line's own count, only when it differs from `drafts`.
    public var recordedDrafts: Int?
    public var reinforced: Int
    public var conflicts: Int
    public var skipped: Int

    enum CodingKeys: String, CodingKey {
        case rowType, id, route, job, state, outcome, startedAt, endedAt, version, requestedModel, reportedModel, tokens
        case costMicros, costMissing, groups, drafts, recordedDrafts, reinforced, conflicts, skipped
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(String.self, forKey: .rowType) == "run" else {
            throw DecodingError.dataCorruptedError(forKey: .rowType, in: c, debugDescription: "rowType is not run")
        }
        id = try c.decode(String.self, forKey: .id)
        route = try c.decode(LearningRoute.self, forKey: .route)
        job = try c.decode(LearningJob.self, forKey: .job)
        state = try c.decode(LearningRunState.self, forKey: .state)
        outcome = try c.nullable(LearningOutcome.self, forKey: .outcome)
        startedAt = try c.decode(Int.self, forKey: .startedAt)
        endedAt = try c.nullable(Int.self, forKey: .endedAt)
        version = try c.nullable(String.self, forKey: .version)
        requestedModel = try c.nullable(String.self, forKey: .requestedModel)
        reportedModel = try c.nullable(String.self, forKey: .reportedModel)
        tokens = try c.nullable(LearningTokens.self, forKey: .tokens)
        costMicros = try c.nullable(Int.self, forKey: .costMicros)
        costMissing = try c.nullable(LearningCostMissing.self, forKey: .costMissing)
        groups = try c.decode(Int.self, forKey: .groups)
        drafts = try c.decode(Int.self, forKey: .drafts)
        recordedDrafts = try c.nullable(Int.self, forKey: .recordedDrafts)
        reinforced = try c.decode(Int.self, forKey: .reinforced)
        conflicts = try c.decode(Int.self, forKey: .conflicts)
        skipped = try c.decode(Int.self, forKey: .skipped)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("run", forKey: .rowType)
        try c.encode(id, forKey: .id)
        try c.encode(route, forKey: .route)
        try c.encode(job, forKey: .job)
        try c.encode(state, forKey: .state)
        try c.encodeNullable(outcome, forKey: .outcome)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encodeNullable(endedAt, forKey: .endedAt)
        try c.encodeNullable(version, forKey: .version)
        try c.encodeNullable(requestedModel, forKey: .requestedModel)
        try c.encodeNullable(reportedModel, forKey: .reportedModel)
        try c.encodeNullable(tokens, forKey: .tokens)
        try c.encodeNullable(costMicros, forKey: .costMicros)
        try c.encodeNullable(costMissing, forKey: .costMissing)
        try c.encode(groups, forKey: .groups)
        try c.encode(drafts, forKey: .drafts)
        try c.encodeNullable(recordedDrafts, forKey: .recordedDrafts)
        try c.encode(reinforced, forKey: .reinforced)
        try c.encode(conflicts, forKey: .conflicts)
        try c.encode(skipped, forKey: .skipped)
    }

    func validate(_ path: String) throws {
        try Check.itemID(id, path + ".id")
        try Check.integer(startedAt, path + ".startedAt")
        try Check.optionalInteger(endedAt, path + ".endedAt")
        for (value, name) in [(version, "version"), (requestedModel, "requestedModel"), (reportedModel, "reportedModel")] {
            if let value { try Check.text(value, path + "." + name, minimum: 1, maximum: 64) }
        }
        try tokens?.validate(path + ".tokens")
        try Check.optionalInteger(costMicros, path + ".costMicros")
        for (value, name) in [(groups, "groups"), (drafts, "drafts"), (reinforced, "reinforced"), (conflicts, "conflicts"),
                              (skipped, "skipped")] {
            try Check.integer(value, path + "." + name)
        }
        try Check.optionalInteger(recordedDrafts, path + ".recordedDrafts")
    }
}

/// One joined group as a list's head (`learningGroup`).
public struct LearningGroup: Hashable, Sendable, Codable, Validatable {
    public var id: String
    public var size: Int
    public var category: RuleGroup?
    public var state: LearningGroupState
    public var oneRulePrevents: Double?
    public var formedAt: Int?
    public var draftId: String?
    public var ruleId: String?

    enum CodingKeys: String, CodingKey { case rowType, id, size, category, state, oneRulePrevents, formedAt, draftId, ruleId }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(String.self, forKey: .rowType) == "group" else {
            throw DecodingError.dataCorruptedError(forKey: .rowType, in: c, debugDescription: "rowType is not group")
        }
        id = try c.decode(String.self, forKey: .id)
        size = try c.decode(Int.self, forKey: .size)
        category = try c.nullable(RuleGroup.self, forKey: .category)
        state = try c.decode(LearningGroupState.self, forKey: .state)
        oneRulePrevents = try c.nullable(Double.self, forKey: .oneRulePrevents)
        formedAt = try c.nullable(Int.self, forKey: .formedAt)
        draftId = try c.nullable(String.self, forKey: .draftId)
        ruleId = try c.nullable(String.self, forKey: .ruleId)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("group", forKey: .rowType)
        try c.encode(id, forKey: .id)
        try c.encode(size, forKey: .size)
        try c.encodeNullable(category, forKey: .category)
        try c.encode(state, forKey: .state)
        try c.encodeNullable(oneRulePrevents, forKey: .oneRulePrevents)
        try c.encodeNullable(formedAt, forKey: .formedAt)
        try c.encodeNullable(draftId, forKey: .draftId)
        try c.encodeNullable(ruleId, forKey: .ruleId)
    }

    func validate(_ path: String) throws {
        try Check.itemID(id, path + ".id")
        try Check.integer(size, path + ".size")
        try Check.optionalProbability(oneRulePrevents, path + ".oneRulePrevents")
        try Check.optionalInteger(formedAt, path + ".formedAt")
        if let draftId { try Check.itemID(draftId, path + ".draftId") }
        if let ruleId { try Check.itemID(ruleId, path + ".ruleId") }
    }
}

/// The PC's current thresholds (`learningThresholds`). A score keeps the number of its own question version.
public struct LearningThresholds: Hashable, Sendable, Codable, Validatable {
    /// The kind request's `standingRule` probability from which a message may become a correction.
    public var kind: Double
    /// The coverage value from which a rule covers a message.
    public var coverage: Double
    /// The group score from which a group is ready to draft.
    public var groupReady: Double
    /// The group score under which a group splits.
    public var groupWait: Double

    func validate(_ path: String) throws {
        try Check.probability(kind, path + ".kind")
        try Check.probability(coverage, path + ".coverage")
        try Check.probability(groupReady, path + ".groupReady")
        try Check.probability(groupWait, path + ".groupWait")
    }
}

/// What a list leaves out of its rows (`learning-page.leftOut`).
public struct LearningLeftOut: Hashable, Sendable, Codable {
    /// Turns whose project cannot be read. Neither the number nor the list holds them.
    public var untraced: Int
    /// Items the number counts and the list holds without details, for the subjects `group`, `rule` and `draft`.
    public var older: Int
    /// Turns dated after this week, which no week counts.
    public var afterThisWeek: Int

    /// Builds the three counts.
    public init(untraced: Int, older: Int, afterThisWeek: Int) {
        self.untraced = untraced
        self.older = older
        self.afterThisWeek = afterThisWeek
    }
}

/// The item a list explains, sent once with its parts (`learning-page.head`).
public enum LearningHead: Hashable, Sendable, Codable, Validatable {
    case group(LearningGroup)
    case rule(LearningRule)
    case draft(LearningDraft)
    case run(LearningRun)

    private enum CodingKeys: String, CodingKey { case rowType }

    public init(from decoder: Decoder) throws {
        switch try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .rowType) {
        case "group": self = .group(try LearningGroup(from: decoder))
        case "rule": self = .rule(try LearningRule(from: decoder))
        case "draft": self = .draft(try LearningDraft(from: decoder))
        case "run": self = .run(try LearningRun(from: decoder))
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown head rowType"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .group(let item): try item.encode(to: encoder)
        case .rule(let item): try item.encode(to: encoder)
        case .draft(let item): try item.encode(to: encoder)
        case .run(let item): try item.encode(to: encoder)
        }
    }

    func validate(_ path: String) throws {
        switch self {
        case .group(let item): try item.validate(path)
        case .rule(let item): try item.validate(path)
        case .draft(let item): try item.validate(path)
        case .run(let item): try item.validate(path)
        }
    }
}

/// One counted item of a list (`learning-page.rows`): a turn, a rule, a draft or a run.
public enum LearningRow: Hashable, Sendable, Codable, Validatable {
    case turn(LearningTurn)
    case rule(LearningRule)
    case draft(LearningDraft)
    case run(LearningRun)

    private enum CodingKeys: String, CodingKey { case rowType }

    public init(from decoder: Decoder) throws {
        switch try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .rowType) {
        case "turn": self = .turn(try LearningTurn(from: decoder))
        case "rule": self = .rule(try LearningRule(from: decoder))
        case "draft": self = .draft(try LearningDraft(from: decoder))
        case "run": self = .run(try LearningRun(from: decoder))
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown rowType"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .turn(let item): try item.encode(to: encoder)
        case .rule(let item): try item.encode(to: encoder)
        case .draft(let item): try item.encode(to: encoder)
        case .run(let item): try item.encode(to: encoder)
        }
    }

    func validate(_ path: String) throws {
        switch self {
        case .turn(let item): try item.validate(path)
        case .rule(let item): try item.validate(path)
        case .draft(let item): try item.validate(path)
        case .run(let item): try item.validate(path)
        }
    }
}

// MARK: Messages

/// The `learning-request` message, from schema revision 4: the phone asks for one page of a list.
public struct LearningRequest: Hashable, Sendable, Codable, Validatable {
    public var id: String
    public var sentAt: Int
    public var subject: LearningSubject
    /// The first row of the page: 0 for a first page, else the `next` of the page before.
    public var from: Int
    /// Null for a first page, else the `listHash` of the first page.
    public var listHash: String?

    /// Builds a request for one page.
    public init(id: String, sentAt: Int, subject: LearningSubject, from: Int, listHash: String?) {
        self.id = id
        self.sentAt = sentAt
        self.subject = subject
        self.from = from
        self.listHash = listHash
    }

    enum CodingKeys: String, CodingKey { case id, sentAt, subject, from, listHash }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        sentAt = try c.decode(Int.self, forKey: .sentAt)
        subject = try c.decode(LearningSubject.self, forKey: .subject)
        from = try c.decode(Int.self, forKey: .from)
        listHash = try c.nullable(String.self, forKey: .listHash)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(sentAt, forKey: .sentAt)
        try c.encode(subject, forKey: .subject)
        try c.encode(from, forKey: .from)
        try c.encodeNullable(listHash, forKey: .listHash)
    }

    func validate(_ path: String) throws {
        try subject.validate(path + ".subject")
        try Check.integer(from, path + ".from")
        if let listHash { try Check.b64u16(listHash, path + ".listHash") }
    }
}

/// The `learning-page` message, from schema revision 4: one page of a list, the answer to one `learning-request`.
public struct LearningPage: Hashable, Sendable, Codable, Validatable {
    public var id: String
    public var sentAt: Int
    public var requestId: String
    public var subject: LearningSubject
    public var state: LearningPageState
    public var storeVersion: Int
    /// When the PC built the list.
    public var asOf: Int
    /// The number on the screen: `total` plus `leftOut.older`.
    public var value: Int
    /// The rows of the whole list.
    public var total: Int
    public var leftOut: LearningLeftOut
    public var from: Int
    /// The first row of the next page, or null on the last page.
    public var next: Int?
    public var listHash: String?
    public var thresholds: LearningThresholds
    public var head: LearningHead?
    public var rows: [LearningRow]

    enum CodingKeys: String, CodingKey {
        case id, sentAt, requestId, subject, state, storeVersion, asOf, value, total, leftOut, from, next, listHash, thresholds
        case head, rows
    }

    /// Builds a page with every field the schema requires.
    public init(id: String, sentAt: Int, requestId: String, subject: LearningSubject, state: LearningPageState,
                storeVersion: Int, asOf: Int, value: Int, total: Int, leftOut: LearningLeftOut, from: Int, next: Int?,
                listHash: String?, thresholds: LearningThresholds, head: LearningHead?, rows: [LearningRow]) {
        self.id = id
        self.sentAt = sentAt
        self.requestId = requestId
        self.subject = subject
        self.state = state
        self.storeVersion = storeVersion
        self.asOf = asOf
        self.value = value
        self.total = total
        self.leftOut = leftOut
        self.from = from
        self.next = next
        self.listHash = listHash
        self.thresholds = thresholds
        self.head = head
        self.rows = rows
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        sentAt = try c.decode(Int.self, forKey: .sentAt)
        requestId = try c.decode(String.self, forKey: .requestId)
        subject = try c.decode(LearningSubject.self, forKey: .subject)
        state = try c.decode(LearningPageState.self, forKey: .state)
        storeVersion = try c.decode(Int.self, forKey: .storeVersion)
        asOf = try c.decode(Int.self, forKey: .asOf)
        value = try c.decode(Int.self, forKey: .value)
        total = try c.decode(Int.self, forKey: .total)
        leftOut = try c.decode(LearningLeftOut.self, forKey: .leftOut)
        from = try c.decode(Int.self, forKey: .from)
        next = try c.nullable(Int.self, forKey: .next)
        listHash = try c.nullable(String.self, forKey: .listHash)
        thresholds = try c.decode(LearningThresholds.self, forKey: .thresholds)
        head = try c.nullable(LearningHead.self, forKey: .head)
        rows = try c.decode([LearningRow].self, forKey: .rows)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(sentAt, forKey: .sentAt)
        try c.encode(requestId, forKey: .requestId)
        try c.encode(subject, forKey: .subject)
        try c.encode(state, forKey: .state)
        try c.encode(storeVersion, forKey: .storeVersion)
        try c.encode(asOf, forKey: .asOf)
        try c.encode(value, forKey: .value)
        try c.encode(total, forKey: .total)
        try c.encode(leftOut, forKey: .leftOut)
        try c.encode(from, forKey: .from)
        try c.encodeNullable(next, forKey: .next)
        try c.encodeNullable(listHash, forKey: .listHash)
        try c.encode(thresholds, forKey: .thresholds)
        try c.encodeNullable(head, forKey: .head)
        try c.encode(rows, forKey: .rows)
    }

    func validate(_ path: String) throws {
        try Check.b64u16(requestId, path + ".requestId")
        try subject.validate(path + ".subject")
        for (value, name) in [(storeVersion, "storeVersion"), (asOf, "asOf"), (self.value, "value"), (total, "total"),
                              (leftOut.untraced, "leftOut.untraced"), (leftOut.older, "leftOut.older"),
                              (leftOut.afterThisWeek, "leftOut.afterThisWeek"), (from, "from")] {
            try Check.integer(value, path + "." + name)
        }
        try Check.optionalInteger(next, path + ".next")
        if let listHash { try Check.b64u16(listHash, path + ".listHash") }
        try thresholds.validate(path + ".thresholds")
        try head?.validate(path + ".head")
        try Check.count(rows, path + ".rows", minimum: 0, maximum: 50)
        for (i, row) in rows.enumerated() { try row.validate(path + ".rows[\(i)]") }
        if state == .ok {
            try Check.that(listHash != nil, path + ".listHash", "a list hash when state is ok")
        } else {
            try Check.that(rows.isEmpty, path + ".rows", "empty unless state is ok")
            try Check.that(head == nil, path + ".head", "null unless state is ok")
            try Check.that(next == nil, path + ".next", "null unless state is ok")
            try Check.that(listHash == nil, path + ".listHash", "null unless state is ok")
        }
    }
}

/// The `learning-words-request` message, from schema revision 4: the phone asks for one row's words.
public struct LearningWordsRequest: Hashable, Sendable, Codable, Validatable {
    public var id: String
    public var sentAt: Int
    public var ref: String
    /// The public half of a fresh reply key.
    public var replyKey: String

    func validate(_ path: String) throws {
        try Check.learningRef(ref, path + ".ref")
        try Check.b64u32(replyKey, path + ".replyKey")
    }
}

/// The `learning-words` message, from schema revision 4: one row's redacted words, sealed to the request's reply key.
public struct LearningWords: Hashable, Sendable, Codable, Validatable {
    public var id: String
    public var sentAt: Int
    public var requestId: String
    public var ref: String
    public var state: LearningWordsState
    /// The words for state `words`, else null.
    public var words: String?
    /// The time of the next allowed request for state `limited`, else null.
    public var nextAt: Int?

    enum CodingKeys: String, CodingKey { case id, sentAt, requestId, ref, state, words, nextAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        sentAt = try c.decode(Int.self, forKey: .sentAt)
        requestId = try c.decode(String.self, forKey: .requestId)
        ref = try c.decode(String.self, forKey: .ref)
        state = try c.decode(LearningWordsState.self, forKey: .state)
        words = try c.nullable(String.self, forKey: .words)
        nextAt = try c.nullable(Int.self, forKey: .nextAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(sentAt, forKey: .sentAt)
        try c.encode(requestId, forKey: .requestId)
        try c.encode(ref, forKey: .ref)
        try c.encode(state, forKey: .state)
        try c.encodeNullable(words, forKey: .words)
        try c.encodeNullable(nextAt, forKey: .nextAt)
    }

    func validate(_ path: String) throws {
        try Check.b64u16(requestId, path + ".requestId")
        try Check.learningRef(ref, path + ".ref")
        if let words { try Check.text(words, path + ".words", minimum: 0, maximum: 300) }
        try Check.optionalInteger(nextAt, path + ".nextAt")
        switch state {
        case .words:
            try Check.that(words.map { !$0.isEmpty } ?? false, path + ".words", "a non-empty string for state words")
            try Check.that(nextAt == nil, path + ".nextAt", "null for state words")
        case .removed, .gone:
            try Check.that(words == nil, path + ".words", "null for state \(state.rawValue)")
            try Check.that(nextAt == nil, path + ".nextAt", "null for state \(state.rawValue)")
        case .limited:
            try Check.that(words == nil, path + ".words", "null for state limited")
            try Check.that(nextAt != nil, path + ".nextAt", "a time for state limited")
        }
    }
}
