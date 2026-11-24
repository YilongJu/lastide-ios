import Foundation

/// What a list screen shows while its rows cannot show (learning evidence design, Table 11).
public enum LearningListPhase: Hashable, Sendable {
    /// A request waits for its page.
    case asking
    /// Rows arrived. More may follow through `nextRequest`.
    case shown
    /// The PC is offline. The definition and the rule still show.
    case offline
    /// The PC speaks a schema revision before 4.
    case needsUpdate
    /// The PC did not answer in 10 s.
    case noAnswer
    /// The list changed between pages more often than the phone asks again.
    case changedTooOften
    /// The PC's answer was `gone`, `limited` or `blocked`.
    case gone, limited, blocked
}

/// What the screen does after a page arrived.
public enum LearningListStep: Hashable, Sendable {
    /// The page answers another request, or a list that already moved on.
    case ignored
    /// The page's rows now show.
    case shown
    /// The list changed on the PC: send this first-page request, and show "The list changed on your PC".
    case askAgain(LearningRequest)
    /// The list stopped: its phase names why.
    case stopped
}

/// One open list on the phone: the pages it received, in memory only (protocol 7.6). The app drops it when the list's
/// screen closes, the app leaves the active state, the PC goes offline or the person picks another PC.
public struct LearningList: Hashable, Sendable {
    /// How often the phone asks again for a list that changed between pages before it stops.
    public static let restartLimit = 3
    /// How long the phone waits for a page, in ms (protocol Table 32).
    public static let answerTimeMs = 10_000

    public let subject: LearningSubject
    public private(set) var phase: LearningListPhase
    /// The id of the request that waits for its page, or nil.
    public private(set) var pendingRequestID: String?
    /// When the waiting request left, in ms.
    public private(set) var pendingSince: Int?
    public private(set) var value: Int = 0
    public private(set) var total: Int = 0
    public private(set) var leftOut = LearningLeftOut(untraced: 0, older: 0, afterThisWeek: 0)
    public private(set) var head: LearningHead?
    public private(set) var rows: [LearningRow] = []
    public private(set) var next: Int?
    public private(set) var listHash: String?
    public private(set) var asOf: Int?
    public private(set) var storeVersion: Int?
    public private(set) var thresholds: LearningThresholds?
    /// True after the list changed on the PC and the phone asked again.
    public private(set) var restarted = false
    /// True after the PC refused a later page for its page limit. The rows read so far stay, and Show More asks again.
    public private(set) var laterPageLimited = false
    private var restarts = 0

    /// A list in a phase without a request, such as `offline` or `needsUpdate`.
    public init(subject: LearningSubject, phase: LearningListPhase) {
        self.subject = subject
        self.phase = phase
    }

    /// A list that asks its PC for the first page.
    public static func ask(_ subject: LearningSubject, now: Int) -> (LearningList, LearningRequest) {
        var list = LearningList(subject: subject, phase: .asking)
        let request = list.firstRequest(now: now)
        return (list, request)
    }

    private mutating func firstRequest(now: Int) -> LearningRequest {
        let request = LearningRequest(id: makeMessageID(), sentAt: now, subject: subject, from: 0, listHash: nil)
        pendingRequestID = request.id
        pendingSince = now
        return request
    }

    /// The request for the next page while `next` holds a value and no request waits.
    public mutating func nextRequest(now: Int) -> LearningRequest? {
        guard phase == .shown, pendingRequestID == nil, let next, let listHash else { return nil }
        let request = LearningRequest(id: makeMessageID(), sentAt: now, subject: subject, from: next, listHash: listHash)
        pendingRequestID = request.id
        pendingSince = now
        return request
    }

    /// The first-page request after `noAnswer`, `changedTooOften` or a page limit, or once the PC came back online.
    public mutating func askAgain(now: Int) -> LearningRequest {
        self = LearningList(subject: subject, phase: .asking)
        return firstRequest(now: now)
    }

    /// Marks the waiting request as unanswered once 10 s passed. Returns true when the phase changed.
    public mutating func checkTimeout(now: Int) -> Bool {
        guard let pendingSince, pendingRequestID != nil, now - pendingSince >= Self.answerTimeMs else { return false }
        pendingRequestID = nil
        self.pendingSince = nil
        phase = .noAnswer
        return true
    }

    /// Applies one `learning-page`.
    public mutating func apply(_ page: LearningPage, now: Int) -> LearningListStep {
        guard let pending = pendingRequestID, page.requestId == pending, page.subject == subject else { return .ignored }
        pendingRequestID = nil
        pendingSince = nil
        if page.state == .limited, page.from > 0, phase == .shown {
            // A refused later page keeps the rows already read: the limit passes in a minute.
            laterPageLimited = true
            return .shown
        }
        switch page.state {
        case .ok:
            laterPageLimited = false
            if page.from == 0 {
                value = page.value
                total = page.total
                leftOut = page.leftOut
                head = page.head
                rows = page.rows
                listHash = page.listHash
                asOf = page.asOf
                storeVersion = page.storeVersion
                thresholds = page.thresholds
            } else {
                // A later page must continue the same list where the rows end.
                guard page.listHash == listHash, page.from == rows.count else { return restart(now: now) }
                rows += page.rows
            }
            next = page.next
            phase = .shown
            return .shown
        case .changed:
            return restart(now: now)
        case .gone:
            stop(.gone)
        case .limited:
            stop(.limited)
        case .blocked:
            stop(.blocked)
        }
        return .stopped
    }

    private mutating func restart(now: Int) -> LearningListStep {
        restarts += 1
        let count = restarts
        guard count <= Self.restartLimit else {
            stop(.changedTooOften)
            return .stopped
        }
        self = LearningList(subject: subject, phase: .asking)
        restarts = count
        restarted = true
        return .askAgain(firstRequest(now: now))
    }

    private mutating func stop(_ phase: LearningListPhase) {
        let subject = self.subject
        self = LearningList(subject: subject, phase: phase)
    }

    /// The sum check against `counts` (design Table 10). The first page's `value` must equal the number of `counts`,
    /// but only when `counts` comes from the same store version as the page: a newer `counts`, such as the one before
    /// another list's first page, may count a new row that this list does not hold yet. The rows read plus
    /// `leftOut.older` must equal `value` once the last page arrived. Returns the two numbers of "Your PC counted {a} and
    /// listed {b}." on a difference, or nil.
    public func mismatch(counts: Counts?) -> (counted: Int, listed: Int)? {
        mismatch(expected: counts.flatMap { $0.storeVersion == storeVersion ? $0.number(for: subject) : nil })
    }

    /// True when `counts` from a newer store version gives this list's number another value. The list then reads again.
    public func isStale(against counts: Counts?) -> Bool {
        guard phase == .shown, let counts, let storeVersion, counts.storeVersion > storeVersion,
              let number = counts.number(for: subject) else { return false }
        return number != value
    }

    /// The first-page request after a newer `counts` changed the list's number. The screen shows "The list changed on
    /// your PC, so it reads again."
    public mutating func readAgain(now: Int) -> LearningRequest {
        self = LearningList(subject: subject, phase: .asking)
        restarted = true
        return firstRequest(now: now)
    }

    /// The sum check of the phone (design Table 10) against a number of the same store version as the page: the first
    /// page's `value` must equal that number, and
    /// the loaded rows plus `leftOut.older` must equal `value` once the last page arrived. Returns the two numbers of
    /// "Your PC counted {a} and listed {b}." on a difference, or nil.
    public func mismatch(expected: Int?) -> (counted: Int, listed: Int)? {
        guard phase == .shown else { return nil }
        if let expected, expected != value { return (expected, value) }
        if next == nil, rows.count + leftOut.older != value || rows.count != total {
            return (value, rows.count + leftOut.older)
        }
        return nil
    }
}

/// The words of one turn row on the screen (protocol 7.6). They live in memory until the row's screen closes.
public enum LearningWordsPhase: Hashable, Sendable {
    /// A request waits for its answer.
    case asking
    /// The PC sent the words.
    case words(String)
    /// The transcript or its line is gone or changed.
    case removed
    /// The row left the lists, or its project is excluded.
    case gone
    /// The PC refused: too many words in the last hour. `nextAt` is the time of the next allowed request.
    case limited(nextAt: Int)
    /// The PC is offline.
    case offline
    /// The PC did not answer in 10 s.
    case noAnswer
    /// The PC speaks a schema revision before 4.
    case needsUpdate
    /// Demo mode reads no words.
    case demo
}
