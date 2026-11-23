import Foundation

/// `push/<pairing id>.json` in the App Group, which the notification service extension writes (design Table 14).
public struct PushState: Hashable, Sendable, Codable {
    /// The `seq` of the newest alert notice the extension opened. An older or equal `seq` is a replay.
    public var lastPushSeq: UInt64
    /// The `seq` of the last alert notice the extension showed with Approve and Delete, or nil before the first one.
    public var shownSeq: UInt64?
    public var storeVersion: Int
    public var queueCount: Int
    /// The phone's clock when the extension wrote the record, in ms.
    public var at: Int

    public init(lastPushSeq: UInt64, shownSeq: UInt64?, storeVersion: Int, queueCount: Int, at: Int) {
        self.lastPushSeq = lastPushSeq
        self.shownSeq = shownSeq
        self.storeVersion = storeVersion
        self.queueCount = queueCount
        self.at = at
    }

    /// The record after the extension opened `opened`, which holds a notice (design 6.4, steps 8 and 10).
    /// `shown` is true when the extension showed the rule text with Approve and Delete. Otherwise the earlier
    /// `shownSeq` stays.
    public static func after(_ opened: OpenedPush, shown: Bool, previous: PushState?, now: Int) -> PushState {
        guard let notice = opened.notice else { preconditionFailure("a push state follows an alert notice") }
        return PushState(lastPushSeq: opened.seq, shownSeq: shown ? opened.seq : previous?.shownSeq,
                         storeVersion: notice.storeVersion, queueCount: notice.queueCount, at: now)
    }
}

/// `counts/<pairing id>.json` in the App Group, which the app writes after each queue snapshot or count update.
public struct CountState: Hashable, Sendable, Codable {
    public var storeVersion: Int
    public var queueCount: Int
    /// The phone's clock when the app wrote the record, in ms.
    public var at: Int

    public init(storeVersion: Int, queueCount: Int, at: Int) {
        self.storeVersion = storeVersion
        self.queueCount = queueCount
        self.at = at
    }
}

/// `extension-run.json` in the App Group: the extension's last outcome, for the diagnostics block.
public struct ExtensionRun: Hashable, Sendable, Codable {
    /// `shown`, `plain`, `timeExpired`, or the raw value of the `PushFailure` that ended the run.
    public var outcome: String
    /// The peak physical footprint in bytes, from `task_info` with `TASK_VM_INFO`, or nil when the call failed.
    public var peakMemory: UInt64?
    public var at: Int

    public init(outcome: String, peakMemory: UInt64?, at: Int) {
        self.outcome = outcome
        self.peakMemory = peakMemory
        self.at = at
    }
}

/// `settings.json` in the App Group, which the app writes and the extension reads.
public struct GroupSettings: Hashable, Sendable, Codable {
    /// The switch "Show rule text in notifications": the text shows once the person unlocks the phone.
    public var showRuleText: Bool
    /// The switch "Show rule text while iPhone is locked": with iOS's "Always" previews, the text also shows on a
    /// locked phone.
    public var showRuleTextWhenLocked: Bool

    public init(showRuleText: Bool, showRuleTextWhenLocked: Bool) {
        self.showRuleText = showRuleText
        self.showRuleTextWhenLocked = showRuleTextWhenLocked
    }

    /// The values before the person changes a switch. Decision D7: the rule text shows after an unlock, and a locked
    /// phone shows it only after the person turns that on.
    public static let standard = GroupSettings(showRuleText: true, showRuleTextWhenLocked: false)
}

/// `widget-push.json` in the App Group, which the widget's push handler writes.
public struct WidgetPushState: Hashable, Sendable, Codable {
    /// The widget push token in lowercase hex, or nil while no widget is placed.
    public var token: String?
    /// The number of placed widgets.
    public var widgets: Int
    public var at: Int

    public init(token: String?, widgets: Int, at: Int) {
        self.token = token
        self.widgets = widgets
        self.at = at
    }
}

/// The newest waiting count of one pairing, from its push and counts records.
public struct WaitingCount: Hashable, Sendable {
    public var storeVersion: Int
    public var queueCount: Int
    public var at: Int

    public init(storeVersion: Int, queueCount: Int, at: Int) {
        self.storeVersion = storeVersion
        self.queueCount = queueCount
        self.at = at
    }

    /// The record with the higher `storeVersion`. A tie goes to the later `at` (design section 6.2).
    public static func newest(push: PushState?, count: CountState?) -> WaitingCount? {
        let candidates = [push.map { WaitingCount(storeVersion: $0.storeVersion, queueCount: $0.queueCount, at: $0.at) },
                          count.map { WaitingCount(storeVersion: $0.storeVersion, queueCount: $0.queueCount, at: $0.at) }]
        return candidates.compactMap { $0 }.max { ($0.storeVersion, $0.at) < ($1.storeVersion, $1.at) }
    }

    /// The badge: the sum of the newest counts over all pairings.
    public static func badge(_ counts: [WaitingCount]) -> Int { counts.reduce(0) { $0 + $1.queueCount } }
}

/// The JSON form of every App Group record: sorted keys, so a file's bytes depend only on its values.
public enum GroupRecord {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}
