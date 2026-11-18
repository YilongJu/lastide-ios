import Foundation

/// A filter chip of the Queue screen (Table 23).
public enum QueueFilter: String, Sendable, CaseIterable {
    case all, new, rewrite, conflict

    /// The chip's label.
    public var label: String {
        switch self {
        case .all: return "All"
        case .new: return "New"
        case .rewrite: return "Rewrite"
        case .conflict: return "Conflict"
        }
    }

    func matches(_ draft: Draft) -> Bool {
        switch self {
        case .all: return true
        case .new: return draft.draftKind == .new
        case .rewrite: return draft.draftKind == .rewrite
        case .conflict: return draft.draftKind == .contradiction
        }
    }
}

/// What a card or a detail screen shows about one item's actions.
public enum ItemStatus: Hashable, Sendable {
    /// The person may act on the item.
    case ready
    /// The PC accepts this item's decisions only on the desktop.
    case desktopOnly
    /// A decision waits in the outbox, and the relay has not answered `stored`.
    case notSent
    /// The relay stored the decision, and the PC has not acknowledged it.
    case waitingForPC
    /// The PC refused the last decision on this item.
    case refused(RefusalReason)

    /// The fixed sentence for this status, or nil for `ready`.
    public var displayText: String? {
        switch self {
        case .ready: return nil
        case .desktopOnly: return "Approve this one on your PC"
        case .notSent: return "Not sent yet"
        case .waitingForPC: return "Waiting for your PC"
        case .refused(let reason): return reason.displayText
        }
    }

    /// Whether the person may start a new decision on the item.
    public var allowsActions: Bool {
        switch self {
        case .ready, .refused: return true
        case .desktopOnly, .notSent, .waitingForPC: return false
        }
    }
}

/// Fixed sentences of the review screens (section 7.5).
public enum ReviewText {
    /// The line under a draft on the detail screen.
    public static let draftedOnPC = "Drafted on your PC"
    /// The rationale and words areas while the PC is offline.
    public static let appearsWhileOnline = "Appears while your PC is online"

    /// The line under a list whose snapshot dropped items.
    public static func moreOnPC(_ omitted: Int) -> String { "\(omitted) more on your PC" }

    /// The card line from the draft's counters, for example "3 corrections, 2 projects".
    public static func evidenceLine(_ draft: Draft) -> String {
        let corrections = draft.evidenceCount == 1 ? "1 correction" : "\(draft.evidenceCount) corrections"
        let projects = draft.projectCount == 1 ? "1 project" : "\(draft.projectCount) projects"
        return "\(corrections), \(projects)"
    }
}

/// Why the phone refused to build a decision before sending it.
public enum ReviewError: Error, Equatable, Sendable {
    case unknownItem
    case desktopOnly
    case decisionPending
    case actionDoesNotFit
    case importedRule
    case invalidText
    case invalidScope
}

/// What an acknowledgement changed, for a short notice on screen.
public enum AcknowledgementOutcome: Hashable, Sendable {
    /// The PC applied the decision on this target.
    case applied(Target)
    /// The PC refused the decision on this target.
    case refused(Target, RefusalReason)
    /// No outbox decision has this id. The phone already handled this acknowledgement.
    case alreadyHandled
}

/// The newest snapshots the phone keeps for one PC. The app stores it in the cache file.
public struct ReviewCache: Hashable, Sendable, Codable {
    public internal(set) var queue: QueueSnapshot?
    public internal(set) var library: LibrarySnapshot?
    public internal(set) var counts: Counts?
    /// The store version in which the phone saw each item. A decision sends it as `storeVersion`.
    var seenAt: [Target: Int] = [:]
    /// The last refusal per item, until the person acts on the item again.
    var refusals: [Target: RefusalReason] = [:]

    /// An empty cache, before the first snapshot.
    public init() {}
}

/// One decision that waits for its acknowledgement (section 6.9).
public struct OutboxEntry: Hashable, Sendable, Codable {
    /// The decision as the phone seals it on every send.
    public let decision: Decision
    /// When the phone last sealed it, in ms, or nil before the first send.
    public internal(set) var lastSentAt: Int?
    /// The `seq` of the last envelope that carried it.
    public internal(set) var lastSeq: UInt64?
    /// Whether the relay answered `stored` for the last envelope.
    public internal(set) var stored: Bool
    /// The reason of the last `dropped` answer, for the diagnostics block.
    public internal(set) var droppedReason: String?
}

/// The phone's queue and library state for one PC: snapshots, filters, the outbox and acknowledgements.
public struct ReviewStore: Hashable, Sendable {
    /// The snapshots and per-item state. Write it to the cache file after each change.
    public private(set) var cache: ReviewCache
    /// The decisions that wait for an acknowledgement. Write them to the outbox file after each change.
    public private(set) var outbox: [OutboxEntry]
    /// True in demo mode: decisions change only this copy and never enter the outbox.
    public let isDemo: Bool

    /// A store for a paired PC, from the stored cache and outbox.
    public init(cache: ReviewCache, outbox: [OutboxEntry]) {
        self.cache = cache
        self.outbox = outbox
        isDemo = false
    }

    /// A demo store drawn from the bundled fixtures of section 8.1.
    public static func demo() throws -> ReviewStore {
        let fixtures = try DemoFixtures.load()
        var store = ReviewStore(cache: ReviewCache(), outbox: [], isDemo: true)
        store.apply(.queue(fixtures.queue))
        store.apply(.library(fixtures.library))
        store.apply(.counts(fixtures.counts))
        return store
    }

    private init(cache: ReviewCache, outbox: [OutboxEntry], isDemo: Bool) {
        self.cache = cache
        self.outbox = outbox
        self.isDemo = isDemo
    }

    // MARK: Reading

    /// Every draft of the queue snapshot, newest first.
    public var drafts: [Draft] { cache.queue?.drafts ?? [] }
    /// Every rule of the library snapshot, newest approval first.
    public var rules: [Rule] { cache.library?.rules ?? [] }
    /// The newest learning counts.
    public var counts: Counts? { cache.counts }
    /// Drafts the PC left out of the queue snapshot.
    public var omittedDrafts: Int { cache.queue?.omitted ?? 0 }
    /// Rules the PC left out of the library snapshot.
    public var omittedRules: Int { cache.library?.omitted ?? 0 }
    /// The Queue badge: the drafts plus `omitted`.
    public var badgeCount: Int { drafts.count + omittedDrafts }
    /// The store versions a `sync` reports in `have`.
    public var have: SnapshotVersions { SnapshotVersions(queue: cache.queue?.storeVersion, library: cache.library?.storeVersion) }

    /// The drafts one filter chip shows.
    public func drafts(_ filter: QueueFilter) -> [Draft] { drafts.filter(filter.matches) }

    /// The draft with this id, if the queue holds it.
    public func draft(id: String) -> Draft? { drafts.first { $0.id == id } }

    /// The rule with this id, if the library holds it.
    public func rule(id: String) -> Rule? { rules.first { $0.id == id } }

    /// What the item's card shows about its actions.
    public func status(of target: Target) -> ItemStatus {
        if let entry = outbox.first(where: { $0.decision.target == target }) { return entry.stored ? .waitingForPC : .notSent }
        if isDesktopOnly(target) { return .desktopOnly }
        if let reason = cache.refusals[target] { return .refused(reason) }
        return .ready
    }

    /// The store version in which the phone saw the item, as a decision sends it.
    public func seenAt(_ target: Target) -> Int? { cache.seenAt[target] }

    // MARK: Messages from the PC

    /// Applies one message from the PC. `queue`, `library`, `counts` and `acknowledgement` change the store.
    /// Returns the outcome of an acknowledgement, and nil for every other message.
    @discardableResult
    public mutating func apply(_ message: SyncMessage) -> AcknowledgementOutcome? {
        switch message {
        case .queue(let snapshot):
            guard cache.queue.map({ snapshot.storeVersion >= $0.storeVersion }) ?? true else { return nil }
            cache.queue = snapshot
            resetItems(of: .draft, ids: snapshot.drafts.map(\.id), version: snapshot.storeVersion)
        case .library(let snapshot):
            guard cache.library.map({ snapshot.storeVersion >= $0.storeVersion }) ?? true else { return nil }
            cache.library = snapshot
            resetItems(of: .rule, ids: snapshot.rules.map(\.id), version: snapshot.storeVersion)
        case .counts(let counts):
            guard cache.counts.map({ counts.storeVersion >= $0.storeVersion }) ?? true else { return nil }
            cache.counts = counts
        case .acknowledgement(let acknowledgement):
            return apply(acknowledgement)
        default:
            break
        }
        return nil
    }

    private mutating func apply(_ acknowledgement: Acknowledgement) -> AcknowledgementOutcome {
        guard let index = outbox.firstIndex(where: { $0.decision.decisionId == acknowledgement.decisionId }) else {
            return .alreadyHandled
        }
        let target = outbox.remove(at: index).decision.target
        switch acknowledgement.result {
        case .applied:
            cache.refusals[target] = nil
            remove(target)
            if let current = acknowledgement.current { upsert(current, version: acknowledgement.storeVersion) }
            return .applied(target)
        case .refused:
            let reason = acknowledgement.reason!
            if reason == .gone { remove(target) }
            if let current = acknowledgement.current { upsert(current, version: acknowledgement.storeVersion) }
            cache.refusals[target] = reason
            return .refused(target, reason)
        }
    }

    // MARK: Decisions

    /// Builds one decision, checks it against Table 21 and adds it to the outbox. In demo mode it changes only this copy.
    public mutating func decide(_ target: Target, action: DecisionAction, text: String?, scopeOptionId: String?,
                                now: Int) throws -> Decision {
        guard let options = scopeOptions(of: target), let version = cache.seenAt[target] else { throw ReviewError.unknownItem }
        guard !isDesktopOnly(target) else { throw ReviewError.desktopOnly }
        guard !outbox.contains(where: { $0.decision.target == target }) else { throw ReviewError.decisionPending }
        guard action.fits(target.targetType) else { throw ReviewError.actionDoesNotFit }
        if action == .edit, rule(id: target.id)?.source == .imported { throw ReviewError.importedRule }
        switch action {
        case .approve:
            break
        case .saveEdit, .edit:
            guard text != nil || scopeOptionId != nil else { throw ReviewError.invalidText }
        case .reject, .delete, .turnOff, .turnOn:
            guard text == nil else { throw ReviewError.invalidText }
            guard scopeOptionId == nil else { throw ReviewError.invalidScope }
        }
        if let text {
            let length = text.unicodeScalars.count
            guard length >= 1, length <= LastideProtocol.largestEditText,
                  !text.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" })
            else { throw ReviewError.invalidText }
        }
        if let scopeOptionId, !options.contains(where: { $0.id == scopeOptionId }) { throw ReviewError.invalidScope }

        let decision = Decision(id: makeMessageID(), sentAt: now, decisionId: makeMessageID(), target: target,
                                storeVersion: version, action: action, text: text, scopeOptionId: scopeOptionId, decidedAt: now)
        try SyncMessage.decision(decision).validate()
        cache.refusals[target] = nil
        if isDemo {
            applyInDemo(decision, now: now)
        } else {
            outbox.append(OutboxEntry(decision: decision, lastSentAt: nil, lastSeq: nil, stored: false, droppedReason: nil))
        }
        return decision
    }

    // MARK: Outbox

    /// The decisions to send now. After a `welcome`: every decision without `stored`, and every one last sent more than 6 days ago.
    public func decisionsToSend(now: Int) -> [Decision] {
        outbox.filter { entry in
            guard entry.stored, let lastSentAt = entry.lastSentAt else { return true }
            return now - lastSentAt > LastideProtocol.outboxResendAgeMs
        }.map(\.decision)
    }

    /// Records that a decision left in the envelope with this `seq`.
    public mutating func markSent(decisionId: String, seq: UInt64, now: Int) {
        guard let index = outbox.firstIndex(where: { $0.decision.decisionId == decisionId }) else { return }
        outbox[index].lastSentAt = now
        outbox[index].lastSeq = seq
        outbox[index].stored = false
    }

    /// Applies a `stored` or `dropped` answer of the relay. Frames for other envelopes change nothing.
    public mutating func apply(relayFrame frame: RelayFrame) {
        switch frame {
        case .stored(to: _, seq: let seq):
            guard let index = outbox.firstIndex(where: { $0.lastSeq == seq }) else { return }
            outbox[index].stored = true
            outbox[index].droppedReason = nil
        case .dropped(to: _, seq: let seq, reason: let reason):
            guard let index = outbox.firstIndex(where: { $0.lastSeq == seq }) else { return }
            outbox[index].stored = false
            outbox[index].droppedReason = reason
        default:
            break
        }
    }

    // MARK: Helpers

    private func isDesktopOnly(_ target: Target) -> Bool {
        switch target.targetType {
        case .draft: return draft(id: target.id)?.desktopOnly ?? false
        case .rule: return rule(id: target.id)?.desktopOnly ?? false
        }
    }

    private func scopeOptions(of target: Target) -> [ScopeOption]? {
        switch target.targetType {
        case .draft: return draft(id: target.id)?.scopeOptions
        case .rule: return rule(id: target.id)?.scopeOptions
        }
    }

    private mutating func resetItems(of type: TargetType, ids: [String], version: Int) {
        let present = Set(ids)
        for key in cache.seenAt.keys where key.targetType == type { cache.seenAt[key] = nil }
        for id in ids { cache.seenAt[Target(targetType: type, id: id)] = version }
        for key in cache.refusals.keys where key.targetType == type && !present.contains(key.id) { cache.refusals[key] = nil }
    }

    private mutating func remove(_ target: Target) {
        switch target.targetType {
        case .draft: cache.queue?.drafts.removeAll { $0.id == target.id }
        case .rule: cache.library?.rules.removeAll { $0.id == target.id }
        }
        cache.seenAt[target] = nil
    }

    private mutating func upsert(_ item: CurrentItem, version: Int) {
        switch item {
        case .draft(let draft):
            guard cache.queue != nil else { return }
            if let index = cache.queue!.drafts.firstIndex(where: { $0.id == draft.id }) {
                cache.queue!.drafts[index] = draft
            } else {
                cache.queue!.drafts.insert(draft, at: 0)
            }
        case .rule(let rule):
            guard cache.library != nil else { return }
            if let index = cache.library!.rules.firstIndex(where: { $0.id == rule.id }) {
                cache.library!.rules[index] = rule
            } else {
                cache.library!.rules.insert(rule, at: 0)
            }
        }
        cache.seenAt[item.target] = version
    }

    private mutating func applyInDemo(_ decision: Decision, now: Int) {
        let target = decision.target
        let option = decision.scopeOptionId.flatMap { id in scopeOptions(of: target)?.first { $0.id == id } }
        switch (target.targetType, decision.action) {
        case (.draft, .approve):
            guard let draft = draft(id: target.id) else { return }
            remove(target)
            let rule = Rule(id: "demo-" + draft.id, changedAtStoreVersion: draft.changedAtStoreVersion,
                            text: decision.text ?? draft.text, scope: option?.scope ?? draft.scope,
                            scopeOptions: draft.scopeOptions, group: draft.group, strength: draft.strength,
                            agents: draft.agents, source: .learned, state: .on, approvedAt: now, editedAt: nil,
                            editedOn: nil, correctionsBeforeApproval: draft.evidenceCount, violationsSinceApproval: 0,
                            violationsLast30Days: 0, lastSeenAt: nil, folderGone: false, desktopOnly: false)
            upsert(.rule(rule), version: decision.storeVersion)
        case (.draft, .saveEdit):
            guard var draft = draft(id: target.id) else { return }
            if let text = decision.text { draft.text = text }
            if let option { draft.scope = option.scope }
            upsert(.draft(draft), version: decision.storeVersion)
        case (.draft, _), (.rule, .delete):
            remove(target)
        case (.rule, .edit):
            guard var rule = rule(id: target.id) else { return }
            if let text = decision.text { rule.text = text }
            if let option { rule.scope = option.scope }
            rule.editedAt = now
            rule.editedOn = .phone
            upsert(.rule(rule), version: decision.storeVersion)
        case (.rule, .turnOff), (.rule, .turnOn):
            guard var rule = rule(id: target.id) else { return }
            rule.state = decision.action == .turnOff ? .off : .on
            upsert(.rule(rule), version: decision.storeVersion)
        case (.rule, _):
            return
        }
    }
}
