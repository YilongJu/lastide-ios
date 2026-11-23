import Foundation

/// What the notification service extension shows for one alert notice, and the outcome code it records in
/// `extension-run.json` (design section 6.4, Table 14a).
public struct NoticeOutcome: Hashable, Sendable {
    public let text: NotificationText
    /// The app icon's badge, or nil when the run did not reach the counts.
    public let badge: Int?
    /// `shown`, `plain`, `settings`, `storage`, or the raw value of the `PushFailure` that ended the run.
    public let outcome: String

    public init(text: NotificationText, badge: Int?, outcome: String) {
        self.text = text
        self.badge = badge
        self.outcome = outcome
    }
}

/// The App Group files and the Keychain as the extension reads and writes them. The extension passes the real
/// stores, and the package tests pass stand-ins.
public struct NoticeStore {
    public var records: () throws -> [PairingRecord]
    public var phoneKey: (PairingRecord) throws -> Data?
    public var loadPush: (PairingID) throws -> PushState?
    public var savePush: (PushState, PairingID) throws -> Void
    public var settings: () throws -> GroupSettings
    public var waitingCounts: () throws -> [WaitingCount]

    public init(records: @escaping () throws -> [PairingRecord], phoneKey: @escaping (PairingRecord) throws -> Data?,
                loadPush: @escaping (PairingID) throws -> PushState?, savePush: @escaping (PushState, PairingID) throws -> Void,
                settings: @escaping () throws -> GroupSettings, waitingCounts: @escaping () throws -> [WaitingCount]) {
        self.records = records
        self.phoneKey = phoneKey
        self.loadPush = loadPush
        self.savePush = savePush
        self.settings = settings
        self.waitingCounts = waitingCounts
    }
}

/// Steps 1 to 12 of design section 6.4 on the stores. The extension adds only the App Group container, the shared
/// Keychain group, iOS's preview setting and the content handler.
public enum NoticeSteps {
    /// Opens the notice, stores its replay mark and counts, then picks the text. `previews` returns iOS's preview
    /// setting, or nil when iOS did not answer in time.
    public static func run(payload: [AnyHashable: Any], store: NoticeStore, previews: () -> PreviewSetting?,
                           now: Int) -> NoticeOutcome {
        do {
            let (opened, previous) = try PushOpener.openNotice(payload: payload, records: try store.records(),
                                                               phoneKey: store.phoneKey,
                                                               state: { try store.loadPush($0.pairingId) })
            guard let notice = opened.notice else { throw PushFailure.badMessage }
            let id = opened.record.pairingId
            // Step 8: the replay mark and the counts reach the disk before any wait. A later step that fails or runs out
            // of time still drops a replay, and the badge and the widget still show the new count.
            try store.savePush(PushState.after(opened, shown: false, previous: previous, now: now), id)
            let badge = WaitingCount.badge(try store.waitingCounts())
            guard let previews = previews() else {
                return NoticeOutcome(text: PushText.fallback, badge: badge, outcome: "settings")
            }
            let showsRuleText = PushText.showsRuleText(try store.settings(), previews: previews)
            let text = PushText.notice(notice, pcName: opened.record.pcName, showsRuleText: showsRuleText)
            guard text.category == PushText.ruleCategory else {
                return NoticeOutcome(text: text, badge: badge, outcome: "plain")
            }
            // Step 10: `shownSeq` marks the one notice whose Approve and Delete the app may act on.
            try store.savePush(PushState.after(opened, shown: true, previous: previous, now: now), id)
            return NoticeOutcome(text: text, badge: badge, outcome: "shown")
        } catch let failure as PushFailure {
            return NoticeOutcome(text: PushText.fallback, badge: nil, outcome: failure.rawValue)
        } catch {
            return NoticeOutcome(text: PushText.fallback, badge: nil, outcome: "storage")
        }
    }
}
