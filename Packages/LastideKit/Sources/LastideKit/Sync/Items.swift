import Foundation

/// Where a draft or a rule applies: the schema's `scopeFields`.
public struct Scope: Hashable, Sendable, Codable, Validatable {
    /// `scope`: this project, a kind of work, or every project.
    public var kind: ScopeKind
    /// The kind of work, set only for `kindOfWork`.
    public var kindOfWork: String?
    /// Project folder names, at least one for `thisProject` and none for `everyProject`.
    public var projectNames: [String]

    /// Builds a scope from its three fields.
    init(kind: ScopeKind, kindOfWork: String?, projectNames: [String]) {
        self.kind = kind
        self.kindOfWork = kindOfWork
        self.projectNames = projectNames
    }

    enum CodingKeys: String, CodingKey { case kind = "scope", kindOfWork, projectNames }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(ScopeKind.self, forKey: .kind)
        kindOfWork = try c.nullable(String.self, forKey: .kindOfWork)
        projectNames = try c.decode([String].self, forKey: .projectNames)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encodeNullable(kindOfWork, forKey: .kindOfWork)
        try c.encode(projectNames, forKey: .projectNames)
    }

    func validate(_ path: String) throws {
        if let kindOfWork { try Check.text(kindOfWork, path + ".kindOfWork", minimum: 1, maximum: 128) }
        try Check.count(projectNames, path + ".projectNames", minimum: 0, maximum: 32)
        try Check.unique(projectNames, path + ".projectNames")
        for (i, name) in projectNames.enumerated() { try Check.text(name, path + ".projectNames[\(i)]", minimum: 1, maximum: 128) }
        switch kind {
        case .thisProject:
            try Check.that(kindOfWork == nil, path + ".kindOfWork", "null for thisProject")
            try Check.that(!projectNames.isEmpty, path + ".projectNames", "at least one project for thisProject")
        case .kindOfWork:
            try Check.that(kindOfWork != nil, path + ".kindOfWork", "a string for kindOfWork")
        case .everyProject:
            try Check.that(kindOfWork == nil, path + ".kindOfWork", "null for everyProject")
            try Check.that(projectNames.isEmpty, path + ".projectNames", "empty for everyProject")
        }
    }
}

/// One scope the person may pick for an item, with its option id.
public struct ScopeOption: Hashable, Sendable, Codable, Validatable {
    /// The option id that a decision's `scopeOptionId` names.
    public var id: String
    /// The scope this option sets.
    public var scope: Scope

    /// Builds an option.
    init(id: String, scope: Scope) {
        self.id = id
        self.scope = scope
    }

    enum CodingKeys: String, CodingKey { case id }

    public init(from decoder: Decoder) throws {
        id = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .id)
        scope = try Scope(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try scope.encode(to: encoder)
    }

    func validate(_ path: String) throws {
        try Check.shortID(id, path + ".id")
        try scope.validate(path)
    }
}

/// One correction behind a draft, without its words. A review comment has no agent: `agent` is null and
/// `commentLabel` names the comment, such as "C7" (protocol 7.3, schema revision 2).
public struct EvidenceItem: Hashable, Sendable, Codable, Validatable {
    public var id: String
    public var at: Int
    public var projectName: String
    /// Null for a review comment.
    public var agent: Agent?
    public var signal: Signal
    /// The review comment's label, present when `agent` is null.
    public var commentLabel: String?

    /// Builds an evidence item.
    init(id: String, at: Int, projectName: String, agent: Agent?, signal: Signal, commentLabel: String? = nil) {
        self.id = id
        self.at = at
        self.projectName = projectName
        self.agent = agent
        self.signal = signal
        self.commentLabel = commentLabel
    }

    enum CodingKeys: String, CodingKey { case id, at, projectName, agent, signal, commentLabel }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        at = try c.decode(Int.self, forKey: .at)
        projectName = try c.decode(String.self, forKey: .projectName)
        agent = try c.nullable(Agent.self, forKey: .agent)
        signal = try c.decode(Signal.self, forKey: .signal)
        commentLabel = try c.decodeIfPresent(String.self, forKey: .commentLabel)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(at, forKey: .at)
        try c.encode(projectName, forKey: .projectName)
        try c.encodeNullable(agent, forKey: .agent)
        try c.encode(signal, forKey: .signal)
        try c.encodeIfPresent(commentLabel, forKey: .commentLabel)
    }

    func validate(_ path: String) throws {
        try Check.shortID(id, path + ".id")
        try Check.integer(at, path + ".at")
        try Check.text(projectName, path + ".projectName", minimum: 1, maximum: 128)
        if let commentLabel { try Check.commentLabel(commentLabel, path + ".commentLabel") }
        if agent == nil {
            try Check.that(commentLabel != nil, path + ".commentLabel", "present when agent is null")
            try Check.that(signal == .reviewComment, path + ".signal", "reviewComment when agent is null")
        }
    }
}

/// A rule text that waits in the review queue on the PC.
public struct Draft: Hashable, Sendable, Codable, Validatable, Identifiable {
    public var id: String
    public var changedAtStoreVersion: Int
    public var draftKind: DraftKind
    public var text: String
    public var scope: Scope
    public var scopeOptions: [ScopeOption]
    public var group: RuleGroup
    public var strength: Strength
    public var agents: [Agent]
    public var desktopOnly: Bool
    public var evidence: [EvidenceItem]
    public var evidenceCount: Int
    public var sessionCount: Int
    public var projectCount: Int
    public var leftOutCount: Int
    public var relatedRuleIds: [String]
    public var createdAt: Int

    func validate(_ path: String) throws {
        try Check.itemID(id, path + ".id")
        try Check.integer(changedAtStoreVersion, path + ".changedAtStoreVersion")
        try Check.text(text, path + ".text", minimum: 1, maximum: 4000)
        try scope.validate(path + ".scope")
        try validateOptions(scopeOptions, path + ".scopeOptions")
        try validateAgents(agents, path + ".agents")
        try Check.count(evidence, path + ".evidence", minimum: 0, maximum: 20)
        for (i, item) in evidence.enumerated() { try item.validate(path + ".evidence[\(i)]") }
        for (value, name) in [(evidenceCount, "evidenceCount"), (sessionCount, "sessionCount"),
                              (projectCount, "projectCount"), (leftOutCount, "leftOutCount"), (createdAt, "createdAt")] {
            try Check.integer(value, path + "." + name)
        }
        try Check.count(relatedRuleIds, path + ".relatedRuleIds", minimum: 0, maximum: 20)
        for (i, ruleID) in relatedRuleIds.enumerated() { try Check.itemID(ruleID, path + ".relatedRuleIds[\(i)]") }
    }
}

/// A rule the person approved.
public struct Rule: Hashable, Sendable, Codable, Validatable, Identifiable {
    public var id: String
    public var changedAtStoreVersion: Int
    public var text: String
    public var scope: Scope
    public var scopeOptions: [ScopeOption]
    public var group: RuleGroup
    public var strength: Strength
    public var agents: [Agent]
    public var source: RuleSource
    public var state: RuleState
    public var approvedAt: Int?
    public var editedAt: Int?
    public var editedOn: EditedOn?
    public var correctionsBeforeApproval: Int
    /// Null while the PC does not measure violations yet (protocol 7.3). The app shows "Not measured yet".
    public var violationsSinceApproval: Int?
    /// Null while the PC does not measure violations yet (protocol 7.3).
    public var violationsLast30Days: Int?
    public var lastSeenAt: Int?
    public var folderGone: Bool
    public var desktopOnly: Bool

    enum CodingKeys: String, CodingKey {
        case id, changedAtStoreVersion, text, scope, scopeOptions, group, strength, agents, source, state, approvedAt
        case editedAt, editedOn, correctionsBeforeApproval, violationsSinceApproval, violationsLast30Days, lastSeenAt
        case folderGone, desktopOnly
    }

    /// Builds a rule from all its fields.
    init(id: String, changedAtStoreVersion: Int, text: String, scope: Scope, scopeOptions: [ScopeOption],
                group: RuleGroup, strength: Strength, agents: [Agent], source: RuleSource, state: RuleState,
                approvedAt: Int?, editedAt: Int?, editedOn: EditedOn?, correctionsBeforeApproval: Int,
                violationsSinceApproval: Int?, violationsLast30Days: Int?, lastSeenAt: Int?, folderGone: Bool,
                desktopOnly: Bool) {
        self.id = id
        self.changedAtStoreVersion = changedAtStoreVersion
        self.text = text
        self.scope = scope
        self.scopeOptions = scopeOptions
        self.group = group
        self.strength = strength
        self.agents = agents
        self.source = source
        self.state = state
        self.approvedAt = approvedAt
        self.editedAt = editedAt
        self.editedOn = editedOn
        self.correctionsBeforeApproval = correctionsBeforeApproval
        self.violationsSinceApproval = violationsSinceApproval
        self.violationsLast30Days = violationsLast30Days
        self.lastSeenAt = lastSeenAt
        self.folderGone = folderGone
        self.desktopOnly = desktopOnly
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        changedAtStoreVersion = try c.decode(Int.self, forKey: .changedAtStoreVersion)
        text = try c.decode(String.self, forKey: .text)
        scope = try c.decode(Scope.self, forKey: .scope)
        scopeOptions = try c.decode([ScopeOption].self, forKey: .scopeOptions)
        group = try c.decode(RuleGroup.self, forKey: .group)
        strength = try c.decode(Strength.self, forKey: .strength)
        agents = try c.decode([Agent].self, forKey: .agents)
        source = try c.decode(RuleSource.self, forKey: .source)
        state = try c.decode(RuleState.self, forKey: .state)
        approvedAt = try c.nullable(Int.self, forKey: .approvedAt)
        editedAt = try c.nullable(Int.self, forKey: .editedAt)
        editedOn = try c.nullable(EditedOn.self, forKey: .editedOn)
        correctionsBeforeApproval = try c.decode(Int.self, forKey: .correctionsBeforeApproval)
        violationsSinceApproval = try c.nullable(Int.self, forKey: .violationsSinceApproval)
        violationsLast30Days = try c.nullable(Int.self, forKey: .violationsLast30Days)
        lastSeenAt = try c.nullable(Int.self, forKey: .lastSeenAt)
        folderGone = try c.decode(Bool.self, forKey: .folderGone)
        desktopOnly = try c.decode(Bool.self, forKey: .desktopOnly)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(changedAtStoreVersion, forKey: .changedAtStoreVersion)
        try c.encode(text, forKey: .text)
        try c.encode(scope, forKey: .scope)
        try c.encode(scopeOptions, forKey: .scopeOptions)
        try c.encode(group, forKey: .group)
        try c.encode(strength, forKey: .strength)
        try c.encode(agents, forKey: .agents)
        try c.encode(source, forKey: .source)
        try c.encode(state, forKey: .state)
        try c.encodeNullable(approvedAt, forKey: .approvedAt)
        try c.encodeNullable(editedAt, forKey: .editedAt)
        try c.encodeNullable(editedOn, forKey: .editedOn)
        try c.encode(correctionsBeforeApproval, forKey: .correctionsBeforeApproval)
        try c.encodeNullable(violationsSinceApproval, forKey: .violationsSinceApproval)
        try c.encodeNullable(violationsLast30Days, forKey: .violationsLast30Days)
        try c.encodeNullable(lastSeenAt, forKey: .lastSeenAt)
        try c.encode(folderGone, forKey: .folderGone)
        try c.encode(desktopOnly, forKey: .desktopOnly)
    }

    func validate(_ path: String) throws {
        try Check.itemID(id, path + ".id")
        try Check.integer(changedAtStoreVersion, path + ".changedAtStoreVersion")
        try Check.text(text, path + ".text", minimum: 1, maximum: 4000)
        try scope.validate(path + ".scope")
        try validateOptions(scopeOptions, path + ".scopeOptions")
        try validateAgents(agents, path + ".agents")
        try Check.optionalInteger(approvedAt, path + ".approvedAt")
        try Check.optionalInteger(editedAt, path + ".editedAt")
        try Check.integer(correctionsBeforeApproval, path + ".correctionsBeforeApproval")
        try Check.optionalInteger(violationsSinceApproval, path + ".violationsSinceApproval")
        try Check.optionalInteger(violationsLast30Days, path + ".violationsLast30Days")
        try Check.optionalInteger(lastSeenAt, path + ".lastSeenAt")
    }
}

/// The draft or the rule a decision acts on.
public struct Target: Hashable, Sendable, Codable, Validatable {
    public var targetType: TargetType
    public var id: String

    /// Names one draft or one rule.
    public init(targetType: TargetType, id: String) {
        self.targetType = targetType
        self.id = id
    }

    func validate(_ path: String) throws { try Check.itemID(id, path + ".id") }
}

/// One week of the Learning screen's charts.
public struct WeekCount: Hashable, Sendable, Codable, Validatable {
    public var weekStart: String
    public var repeatCorrections: Int
    public var violations: Int

    func validate(_ path: String) throws {
        try Check.weekStart(weekStart, path + ".weekStart")
        try Check.integer(repeatCorrections, path + ".repeatCorrections")
        try Check.integer(violations, path + ".violations")
    }
}

/// The app's version and build in a pair request.
public struct AppInfo: Hashable, Sendable, Codable {
    public var version: String
    public var build: Int

    /// Builds the app field of a pair request.
    public init(version: String, build: Int) {
        self.version = version
        self.build = build
    }
}

/// The person's agreement to the disclosure.
public struct Consent: Hashable, Sendable, Codable {
    public var disclosure: String
    public var acceptedAt: Int

    /// Records agreement to the `outside-ai-v1` disclosure.
    init(acceptedAt: Int) {
        disclosure = LastideProtocol.disclosureID
        self.acceptedAt = acceptedAt
    }
}

/// The words of one evidence item, or why the PC sent none.
public struct EvidenceWords: Hashable, Sendable, Codable, Validatable {
    public var evidenceId: String
    public var state: EvidenceState
    public var words: String?

    enum CodingKeys: String, CodingKey { case evidenceId, state, words }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        evidenceId = try c.decode(String.self, forKey: .evidenceId)
        state = try c.decode(EvidenceState.self, forKey: .state)
        words = try c.nullable(String.self, forKey: .words)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(evidenceId, forKey: .evidenceId)
        try c.encode(state, forKey: .state)
        try c.encodeNullable(words, forKey: .words)
    }

    func validate(_ path: String) throws {
        try Check.shortID(evidenceId, path + ".evidenceId")
        if let words { try Check.text(words, path + ".words", minimum: 0, maximum: 300) }
        if state == .words {
            try Check.that(words != nil && !words!.isEmpty, path + ".words", "a non-empty string for state words")
        } else {
            try Check.that(words == nil, path + ".words", "null unless state is words")
        }
    }
}

/// The current draft or rule that an acknowledgement carries.
public enum CurrentItem: Hashable, Sendable, Codable, Validatable {
    case draft(Draft)
    case rule(Rule)

    enum CodingKeys: String, CodingKey { case targetType, draft, rule }

    /// The target this item answers to.
    public var target: Target {
        switch self {
        case .draft(let draft): return Target(targetType: .draft, id: draft.id)
        case .rule(let rule): return Target(targetType: .rule, id: rule.id)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(TargetType.self, forKey: .targetType) {
        case .draft: self = .draft(try c.decode(Draft.self, forKey: .draft))
        case .rule: self = .rule(try c.decode(Rule.self, forKey: .rule))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .draft(let draft):
            try c.encode(TargetType.draft, forKey: .targetType)
            try c.encode(draft, forKey: .draft)
        case .rule(let rule):
            try c.encode(TargetType.rule, forKey: .targetType)
            try c.encode(rule, forKey: .rule)
        }
    }

    func validate(_ path: String) throws {
        switch self {
        case .draft(let draft): try draft.validate(path + ".draft")
        case .rule(let rule): try rule.validate(path + ".rule")
        }
    }
}

/// The short draft that a phase 7 `notice` carries.
public struct NoticeDraft: Hashable, Sendable, Codable, Validatable {
    public var id: String
    public var changedAtStoreVersion: Int
    public var draftKind: DraftKind
    public var text: String
    public var scope: Scope

    func validate(_ path: String) throws {
        try Check.itemID(id, path + ".id")
        try Check.integer(changedAtStoreVersion, path + ".changedAtStoreVersion")
        try Check.text(text, path + ".text", minimum: 1, maximum: 600)
        try scope.validate(path + ".scope")
    }
}

/// The store versions of the snapshots a phone holds, as `sync.have` sends them.
public struct SnapshotVersions: Hashable, Sendable, Codable {
    public var queue: Int?
    public var library: Int?

    /// Names the held versions, or null for a snapshot the phone does not hold.
    init(queue: Int?, library: Int?) {
        self.queue = queue
        self.library = library
    }

    enum CodingKeys: String, CodingKey { case queue, library }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        queue = try c.nullable(Int.self, forKey: .queue)
        library = try c.nullable(Int.self, forKey: .library)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeNullable(queue, forKey: .queue)
        try c.encodeNullable(library, forKey: .library)
    }
}

func validateOptions(_ options: [ScopeOption], _ path: String) throws {
    try Check.count(options, path, minimum: 1, maximum: 8)
    for (i, option) in options.enumerated() { try option.validate(path + "[\(i)]") }
}

func validateAgents(_ agents: [Agent], _ path: String) throws {
    try Check.count(agents, path, minimum: 1, maximum: 2)
    try Check.unique(agents, path)
}
