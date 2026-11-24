import Foundation

/// The `pair-request` message: the phone's key and its consent, sealed to the PC key.
public struct PairRequest: Hashable, Sendable, Codable, Validatable {
    public var id: String
    public var sentAt: Int
    public var ticket: String
    public var phoneId: String
    public var phoneKey: String
    public var deviceName: String
    public var model: String
    public var app: AppInfo
    public var schema: Int
    public var consent: Consent

    /// Builds a pair request with every field the schema requires.
    init(id: String, sentAt: Int, ticket: String, phoneId: String, phoneKey: String, deviceName: String,
                model: String, app: AppInfo, schema: Int, consent: Consent) {
        self.id = id
        self.sentAt = sentAt
        self.ticket = ticket
        self.phoneId = phoneId
        self.phoneKey = phoneKey
        self.deviceName = deviceName
        self.model = model
        self.app = app
        self.schema = schema
        self.consent = consent
    }

    func validate(_ path: String) throws {
        try Check.b64u16(ticket, path + ".ticket")
        try Check.b64u16(phoneId, path + ".phoneId")
        try Check.b64u32(phoneKey, path + ".phoneKey")
        try Check.text(deviceName, path + ".deviceName", minimum: 1, maximum: 64)
        try Check.model(model, path + ".model")
        try Check.text(app.version, path + ".app.version", minimum: 1, maximum: 32)
        try Check.that(app.build >= 1 && app.build <= LastideProtocol.largestInteger, path + ".app.build", "integer of at least 1")
        try Check.schemaRevision(schema, path + ".schema")
        try Check.that(consent.disclosure == LastideProtocol.disclosureID, path + ".consent.disclosure", "outside-ai-v1")
        try Check.integer(consent.acceptedAt, path + ".consent.acceptedAt")
    }
}

/// The `pair-received` message: the PC took this phone's request.
public struct PairReceived: Hashable, Sendable, Codable, Validatable {
    public var id: String
    public var sentAt: Int
    public var pairingId: String
    public var phoneId: String

    func validate(_ path: String) throws {
        try Check.b64u16(pairingId, path + ".pairingId")
        try Check.b64u16(phoneId, path + ".phoneId")
    }
}

/// The `pair-accept` message: the person typed the right code.
public struct PairAccept: Hashable, Sendable, Codable, Validatable {
    public var id: String
    public var sentAt: Int
    public var pairingId: String
    public var phoneId: String
    public var phoneToken: String
    public var pcName: String
    public var schema: Int
    public var features: [Feature]

    func validate(_ path: String) throws {
        try Check.b64u16(pairingId, path + ".pairingId")
        try Check.b64u16(phoneId, path + ".phoneId")
        try Check.b64u32(phoneToken, path + ".phoneToken")
        try Check.text(pcName, path + ".pcName", minimum: 1, maximum: 64)
        try Check.schemaRevision(schema, path + ".schema")
        try Check.unique(features, path + ".features")
        try Check.that(features.contains(.mailbox), path + ".features", "contains mailbox")
    }
}

/// The `pair-refuse` message: the PC ended the pairing.
public struct PairRefuse: Hashable, Sendable, Codable, Validatable {
    public var id: String
    public var sentAt: Int
    public var pairingId: String
    public var phoneId: String
    public var reason: PairRefuseReason

    func validate(_ path: String) throws {
        try Check.b64u16(pairingId, path + ".pairingId")
        try Check.b64u16(phoneId, path + ".phoneId")
    }
}

/// The `queue` snapshot: the drafts in the review queue, newest first.
public struct QueueSnapshot: Hashable, Sendable, Codable, Validatable {
    public var id: String
    public var sentAt: Int
    public var schema: Int
    public var storeVersion: Int
    public var omitted: Int
    public var drafts: [Draft]

    func validate(_ path: String) throws {
        try Check.schemaRevision(schema, path + ".schema")
        try Check.integer(storeVersion, path + ".storeVersion")
        try Check.integer(omitted, path + ".omitted")
        for (i, draft) in drafts.enumerated() { try draft.validate(path + ".drafts[\(i)]") }
    }
}

/// The `library` snapshot: the approved rules, newest approval first.
public struct LibrarySnapshot: Hashable, Sendable, Codable, Validatable {
    public var id: String
    public var sentAt: Int
    public var schema: Int
    public var storeVersion: Int
    public var omitted: Int
    public var rules: [Rule]

    func validate(_ path: String) throws {
        try Check.schemaRevision(schema, path + ".schema")
        try Check.integer(storeVersion, path + ".storeVersion")
        try Check.integer(omitted, path + ".omitted")
        for (i, rule) in rules.enumerated() { try rule.validate(path + ".rules[\(i)]") }
    }
}

/// The `counts` message: the Learning screen's numbers and weekly series.
public struct Counts: Hashable, Sendable, Codable, Validatable {
    public var id: String
    public var sentAt: Int
    public var schema: Int
    public var storeVersion: Int
    /// Null while the PC does not measure repeat corrections yet (protocol 7.3).
    public var repeatCorrectionsThisWeek: Int?
    /// Null while the PC does not measure repeat corrections yet.
    public var repeatCorrectionsLastWeek: Int?
    public var rulesApproved: Int
    /// Null while the PC does not measure violations yet.
    public var violationsThisWeek: Int?
    public var draftsToday: Int
    /// Null: drafts have no cap of their own. The drafting runs have one (`draftingRunCap`).
    public var draftCap: Int?
    /// Oldest week first.
    public var weeks: [WeekCount]
    /// The drafting runs of the PC's local day, from schema revision 2. Absent from a revision 1 PC.
    public var draftingRunsToday: Int?
    /// The PC's cap of drafting runs a day, from schema revision 2. Absent from a revision 1 PC.
    public var draftingRunCap: Int?
    /// The principles in import drafts that wait on the PC, from schema revision 2. Absent from a revision 1 PC.
    public var importRulesWaiting: Int?
    /// Rules approved this week and not deleted, from schema revision 4. Absent from an older PC.
    public var rulesApprovedThisWeek: Int?
    /// Last week's repeat corrections typed before this weekday and clock time, from schema revision 4. Absent from an
    /// older PC, and null while last week is not measured.
    public var repeatCorrectionsLastWeekByNow: Int??
    /// Last week's violations by this weekday and clock time, from schema revision 4.
    public var violationsLastWeekByNow: Int??
    /// Today's drafting runs that finished, from schema revision 4.
    public var draftingRunsFinishedToday: Int?
    /// The time from which rule learning asked about turns, from schema revision 4. Null before the PC's first call.
    public var measuredFrom: Int??
    /// The PC's local date when it built the counts, from schema revision 4. The phone sends it as `day`.
    public var today: String?

    enum CodingKeys: String, CodingKey {
        case id, sentAt, schema, storeVersion, repeatCorrectionsThisWeek, repeatCorrectionsLastWeek, rulesApproved
        case violationsThisWeek, draftsToday, draftCap, weeks, draftingRunsToday, draftingRunCap, importRulesWaiting
        case rulesApprovedThisWeek, repeatCorrectionsLastWeekByNow, violationsLastWeekByNow, draftingRunsFinishedToday
        case measuredFrom, today
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        sentAt = try c.decode(Int.self, forKey: .sentAt)
        schema = try c.decode(Int.self, forKey: .schema)
        storeVersion = try c.decode(Int.self, forKey: .storeVersion)
        repeatCorrectionsThisWeek = try c.nullable(Int.self, forKey: .repeatCorrectionsThisWeek)
        repeatCorrectionsLastWeek = try c.nullable(Int.self, forKey: .repeatCorrectionsLastWeek)
        rulesApproved = try c.decode(Int.self, forKey: .rulesApproved)
        violationsThisWeek = try c.nullable(Int.self, forKey: .violationsThisWeek)
        draftsToday = try c.decode(Int.self, forKey: .draftsToday)
        draftCap = try c.nullable(Int.self, forKey: .draftCap)
        weeks = try c.decode([WeekCount].self, forKey: .weeks)
        draftingRunsToday = try c.decodeIfPresent(Int.self, forKey: .draftingRunsToday)
        draftingRunCap = try c.decodeIfPresent(Int.self, forKey: .draftingRunCap)
        importRulesWaiting = try c.decodeIfPresent(Int.self, forKey: .importRulesWaiting)
        rulesApprovedThisWeek = try c.decodeIfPresent(Int.self, forKey: .rulesApprovedThisWeek)
        repeatCorrectionsLastWeekByNow = try c.optionalNullable(Int.self, forKey: .repeatCorrectionsLastWeekByNow)
        violationsLastWeekByNow = try c.optionalNullable(Int.self, forKey: .violationsLastWeekByNow)
        draftingRunsFinishedToday = try c.decodeIfPresent(Int.self, forKey: .draftingRunsFinishedToday)
        measuredFrom = try c.optionalNullable(Int.self, forKey: .measuredFrom)
        today = try c.decodeIfPresent(String.self, forKey: .today)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(sentAt, forKey: .sentAt)
        try c.encode(schema, forKey: .schema)
        try c.encode(storeVersion, forKey: .storeVersion)
        try c.encodeNullable(repeatCorrectionsThisWeek, forKey: .repeatCorrectionsThisWeek)
        try c.encodeNullable(repeatCorrectionsLastWeek, forKey: .repeatCorrectionsLastWeek)
        try c.encode(rulesApproved, forKey: .rulesApproved)
        try c.encodeNullable(violationsThisWeek, forKey: .violationsThisWeek)
        try c.encode(draftsToday, forKey: .draftsToday)
        try c.encodeNullable(draftCap, forKey: .draftCap)
        try c.encode(weeks, forKey: .weeks)
        try c.encodeIfPresent(draftingRunsToday, forKey: .draftingRunsToday)
        try c.encodeIfPresent(draftingRunCap, forKey: .draftingRunCap)
        try c.encodeIfPresent(importRulesWaiting, forKey: .importRulesWaiting)
        try c.encodeIfPresent(rulesApprovedThisWeek, forKey: .rulesApprovedThisWeek)
        try c.encodeOptionalNullable(repeatCorrectionsLastWeekByNow, forKey: .repeatCorrectionsLastWeekByNow)
        try c.encodeOptionalNullable(violationsLastWeekByNow, forKey: .violationsLastWeekByNow)
        try c.encodeIfPresent(draftingRunsFinishedToday, forKey: .draftingRunsFinishedToday)
        try c.encodeOptionalNullable(measuredFrom, forKey: .measuredFrom)
        try c.encodeIfPresent(today, forKey: .today)
    }

    func validate(_ path: String) throws {
        try Check.schemaRevision(schema, path + ".schema")
        for (value, name) in [(storeVersion, "storeVersion"), (rulesApproved, "rulesApproved"), (draftsToday, "draftsToday")] {
            try Check.integer(value, path + "." + name)
        }
        for (value, name) in [(repeatCorrectionsThisWeek, "repeatCorrectionsThisWeek"),
                              (repeatCorrectionsLastWeek, "repeatCorrectionsLastWeek"),
                              (violationsThisWeek, "violationsThisWeek"), (draftCap, "draftCap"),
                              (draftingRunsToday, "draftingRunsToday"), (draftingRunCap, "draftingRunCap"),
                              (importRulesWaiting, "importRulesWaiting"), (rulesApprovedThisWeek, "rulesApprovedThisWeek"),
                              (repeatCorrectionsLastWeekByNow ?? nil, "repeatCorrectionsLastWeekByNow"),
                              (violationsLastWeekByNow ?? nil, "violationsLastWeekByNow"),
                              (draftingRunsFinishedToday, "draftingRunsFinishedToday"), (measuredFrom ?? nil, "measuredFrom")] {
            try Check.optionalInteger(value, path + "." + name)
        }
        if let today { try Check.weekStart(today, path + ".today") }
        try Check.count(weeks, path + ".weeks", minimum: 0, maximum: 12)
        for (i, week) in weeks.enumerated() { try week.validate(path + ".weeks[\(i)]") }
    }
}

/// The `evidence` message: the redacted words behind one draft, sealed to a reply key.
public struct Evidence: Hashable, Sendable, Codable, Validatable {
    public var id: String
    public var sentAt: Int
    public var requestId: String
    public var draftId: String
    public var changedAtStoreVersion: Int
    public var rationale: String?
    public var items: [EvidenceWords]

    enum CodingKeys: String, CodingKey { case id, sentAt, requestId, draftId, changedAtStoreVersion, rationale, items }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        sentAt = try c.decode(Int.self, forKey: .sentAt)
        requestId = try c.decode(String.self, forKey: .requestId)
        draftId = try c.decode(String.self, forKey: .draftId)
        changedAtStoreVersion = try c.decode(Int.self, forKey: .changedAtStoreVersion)
        rationale = try c.nullable(String.self, forKey: .rationale)
        items = try c.decode([EvidenceWords].self, forKey: .items)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(sentAt, forKey: .sentAt)
        try c.encode(requestId, forKey: .requestId)
        try c.encode(draftId, forKey: .draftId)
        try c.encode(changedAtStoreVersion, forKey: .changedAtStoreVersion)
        try c.encodeNullable(rationale, forKey: .rationale)
        try c.encode(items, forKey: .items)
    }

    func validate(_ path: String) throws {
        try Check.b64u16(requestId, path + ".requestId")
        try Check.itemID(draftId, path + ".draftId")
        try Check.integer(changedAtStoreVersion, path + ".changedAtStoreVersion")
        if let rationale { try Check.text(rationale, path + ".rationale", minimum: 0, maximum: 1000) }
        try Check.count(items, path + ".items", minimum: 0, maximum: 20)
        for (i, item) in items.enumerated() { try item.validate(path + ".items[\(i)]") }
    }
}

/// The `acknowledgement` message: the PC's answer to one decision.
public struct Acknowledgement: Hashable, Sendable, Codable, Validatable {
    public var id: String
    public var sentAt: Int
    public var decisionId: String
    public var result: AcknowledgementResult
    public var appliedAt: Int?
    public var reason: RefusalReason?
    public var storeVersion: Int
    /// The item after the answer, or null when it left both lists.
    public var current: CurrentItem?

    enum CodingKeys: String, CodingKey { case id, sentAt, decisionId, result, appliedAt, reason, storeVersion, current }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        sentAt = try c.decode(Int.self, forKey: .sentAt)
        decisionId = try c.decode(String.self, forKey: .decisionId)
        result = try c.decode(AcknowledgementResult.self, forKey: .result)
        appliedAt = try c.nullable(Int.self, forKey: .appliedAt)
        reason = try c.nullable(RefusalReason.self, forKey: .reason)
        storeVersion = try c.decode(Int.self, forKey: .storeVersion)
        current = try c.nullable(CurrentItem.self, forKey: .current)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(sentAt, forKey: .sentAt)
        try c.encode(decisionId, forKey: .decisionId)
        try c.encode(result, forKey: .result)
        try c.encodeNullable(appliedAt, forKey: .appliedAt)
        try c.encodeNullable(reason, forKey: .reason)
        try c.encode(storeVersion, forKey: .storeVersion)
        try c.encodeNullable(current, forKey: .current)
    }

    func validate(_ path: String) throws {
        try Check.b64u16(decisionId, path + ".decisionId")
        try Check.optionalInteger(appliedAt, path + ".appliedAt")
        try Check.integer(storeVersion, path + ".storeVersion")
        switch result {
        case .applied:
            try Check.that(appliedAt != nil, path + ".appliedAt", "a time when applied")
            try Check.that(reason == nil, path + ".reason", "null when applied")
        case .refused:
            try Check.that(appliedAt == nil, path + ".appliedAt", "null when refused")
            try Check.that(reason != nil, path + ".reason", "a reason when refused")
        }
        try current?.validate(path + ".current")
    }
}

/// The `decision` message: the phone's action on one draft or one rule.
public struct Decision: Hashable, Sendable, Codable, Validatable {
    public var id: String
    public var sentAt: Int
    public var decisionId: String
    public var target: Target
    public var storeVersion: Int
    public var action: DecisionAction
    public var text: String?
    public var scopeOptionId: String?
    public var decidedAt: Int

    /// Builds a decision with every field the schema requires.
    init(id: String, sentAt: Int, decisionId: String, target: Target, storeVersion: Int, action: DecisionAction,
                text: String?, scopeOptionId: String?, decidedAt: Int) {
        self.id = id
        self.sentAt = sentAt
        self.decisionId = decisionId
        self.target = target
        self.storeVersion = storeVersion
        self.action = action
        self.text = text
        self.scopeOptionId = scopeOptionId
        self.decidedAt = decidedAt
    }

    enum CodingKeys: String, CodingKey { case id, sentAt, decisionId, target, storeVersion, action, text, scopeOptionId, decidedAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        sentAt = try c.decode(Int.self, forKey: .sentAt)
        decisionId = try c.decode(String.self, forKey: .decisionId)
        target = try c.decode(Target.self, forKey: .target)
        storeVersion = try c.decode(Int.self, forKey: .storeVersion)
        action = try c.decode(DecisionAction.self, forKey: .action)
        text = try c.nullable(String.self, forKey: .text)
        scopeOptionId = try c.nullable(String.self, forKey: .scopeOptionId)
        decidedAt = try c.decode(Int.self, forKey: .decidedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(sentAt, forKey: .sentAt)
        try c.encode(decisionId, forKey: .decisionId)
        try c.encode(target, forKey: .target)
        try c.encode(storeVersion, forKey: .storeVersion)
        try c.encode(action, forKey: .action)
        try c.encodeNullable(text, forKey: .text)
        try c.encodeNullable(scopeOptionId, forKey: .scopeOptionId)
        try c.encode(decidedAt, forKey: .decidedAt)
    }

    func validate(_ path: String) throws {
        try Check.b64u16(decisionId, path + ".decisionId")
        try target.validate(path + ".target")
        try Check.integer(storeVersion, path + ".storeVersion")
        if let text {
            try Check.text(text, path + ".text", minimum: 1, maximum: LastideProtocol.largestEditText)
            try Check.oneLine(text, path + ".text")
        }
        if let scopeOptionId { try Check.shortID(scopeOptionId, path + ".scopeOptionId") }
        try Check.integer(decidedAt, path + ".decidedAt")
    }
}

/// The `sync` message: the phone asks for fresh snapshots.
public struct SyncRequest: Hashable, Sendable, Codable, Validatable {
    public var id: String
    public var sentAt: Int
    public var schema: Int
    public var have: SnapshotVersions

    /// Builds a sync request.
    public init(id: String, sentAt: Int, schema: Int, have: SnapshotVersions) {
        self.id = id
        self.sentAt = sentAt
        self.schema = schema
        self.have = have
    }

    func validate(_ path: String) throws {
        try Check.schemaRevision(schema, path + ".schema")
        try Check.optionalInteger(have.queue, path + ".have.queue")
        try Check.optionalInteger(have.library, path + ".have.library")
    }
}

/// The `evidence-request` message: the phone asks for the words behind one draft.
public struct EvidenceRequest: Hashable, Sendable, Codable, Validatable {
    public var id: String
    public var sentAt: Int
    public var draftId: String
    public var storeVersion: Int
    public var replyKey: String

    func validate(_ path: String) throws {
        try Check.itemID(draftId, path + ".draftId")
        try Check.integer(storeVersion, path + ".storeVersion")
        try Check.b64u32(replyKey, path + ".replyKey")
    }
}

/// The `unpair` message: the person removed the PC on the phone.
public struct Unpair: Hashable, Sendable, Codable, Validatable {
    public var id: String
    public var sentAt: Int

    /// Builds an unpair message.
    public init(id: String, sentAt: Int) {
        self.id = id
        self.sentAt = sentAt
    }

    func validate(_ path: String) throws {}
}

/// The `error` message: a message that opened but could not be used.
public struct ErrorMessage: Hashable, Sendable, Codable, Validatable {
    public var id: String
    public var sentAt: Int
    public var inReplyTo: String?
    public var code: ErrorCode
    public var detail: String

    /// Builds an error message.
    init(id: String, sentAt: Int, inReplyTo: String?, code: ErrorCode, detail: String) {
        self.id = id
        self.sentAt = sentAt
        self.inReplyTo = inReplyTo
        self.code = code
        self.detail = detail
    }

    enum CodingKeys: String, CodingKey { case id, sentAt, inReplyTo, code, detail }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        sentAt = try c.decode(Int.self, forKey: .sentAt)
        inReplyTo = try c.nullable(String.self, forKey: .inReplyTo)
        code = try c.decode(ErrorCode.self, forKey: .code)
        detail = try c.decode(String.self, forKey: .detail)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(sentAt, forKey: .sentAt)
        try c.encodeNullable(inReplyTo, forKey: .inReplyTo)
        try c.encode(code, forKey: .code)
        try c.encode(detail, forKey: .detail)
    }

    func validate(_ path: String) throws {
        if let inReplyTo { try Check.b64u16(inReplyTo, path + ".inReplyTo") }
        try Check.text(detail, path + ".detail", minimum: 0, maximum: 200)
    }
}

/// The phase 7 `notice` message: a new draft while the phone is offline.
public struct Notice: Hashable, Sendable, Codable, Validatable {
    public var id: String
    public var sentAt: Int
    public var storeVersion: Int
    public var queueCount: Int
    public var draft: NoticeDraft?

    enum CodingKeys: String, CodingKey { case id, sentAt, storeVersion, queueCount, draft }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        sentAt = try c.decode(Int.self, forKey: .sentAt)
        storeVersion = try c.decode(Int.self, forKey: .storeVersion)
        queueCount = try c.decode(Int.self, forKey: .queueCount)
        draft = try c.nullable(NoticeDraft.self, forKey: .draft)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(sentAt, forKey: .sentAt)
        try c.encode(storeVersion, forKey: .storeVersion)
        try c.encode(queueCount, forKey: .queueCount)
        try c.encodeNullable(draft, forKey: .draft)
    }

    func validate(_ path: String) throws {
        try Check.integer(storeVersion, path + ".storeVersion")
        try Check.integer(queueCount, path + ".queueCount")
        try draft?.validate(path + ".draft")
    }
}

/// The phase 7 `count-update` message, from schema revision 3: a count change while the phone is offline (protocol 9.3).
public struct CountUpdate: Hashable, Sendable, Codable, Validatable {
    public var id: String
    public var sentAt: Int
    public var storeVersion: Int
    public var queueCount: Int

    func validate(_ path: String) throws {
        try Check.integer(storeVersion, path + ".storeVersion")
        try Check.integer(queueCount, path + ".queueCount")
    }
}
