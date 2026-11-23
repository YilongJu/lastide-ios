import Foundation
import LastideKit
import UserNotifications

/// The notification service extension (design section 6.4, protocol 9.4).
///
/// It opens each alert notice in Auth mode with the pairing's phone key from the shared Keychain group, drops a replay,
/// and shows the PC's name and the draft text with Approve and Delete when the rule text may show. Any failed step, a
/// replay or the end of the extension's time shows the fixed text with the plain category. The extension keeps the
/// relay's `userInfo` as it came and never adds a `lastide` key.
final class NotificationService: UNNotificationServiceExtension {
    private let lock = NSLock()
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var content: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        lock.lock()
        self.contentHandler = contentHandler
        self.content = content
        lock.unlock()
        let result = NoticeRun.run(payload: request.content.userInfo, now: NoticeRun.currentTime())
        finish(result.text, badge: result.badge, outcome: result.outcome)
    }

    override func serviceExtensionTimeWillExpire() {
        finish(PushText.fallback, badge: nil, outcome: "timeExpired")
    }

    /// Sets the text once, writes the run's outcome, and hands the content to iOS. A second call does nothing.
    private func finish(_ text: NotificationText, badge: Int?, outcome: String) {
        lock.lock()
        let handler = contentHandler
        let content = self.content
        contentHandler = nil
        lock.unlock()
        guard let handler, let content else { return }
        content.title = text.title
        content.subtitle = text.subtitle
        content.body = text.body
        content.categoryIdentifier = text.category
        if let badge { content.badge = NSNumber(value: badge) }
        NoticeRun.record(outcome)
        handler(content)
    }
}

/// Steps 1 to 12 of design section 6.4, on the App Group files and the shared Keychain group.
enum NoticeRun {
    struct Result {
        let text: NotificationText
        let badge: Int?
        /// `shown`, `plain`, or the step that failed.
        let outcome: String
    }

    static func currentTime() -> Int { Int((Date().timeIntervalSince1970 * 1_000).rounded(.down)) }

    static func run(payload: [AnyHashable: Any], now: Int) -> Result {
        do {
            let group = try GroupFiles.shared()
            let secrets = KeychainStore(accessGroup: try KeychainGroup.shared())
            let (opened, previous) = try PushOpener.openNotice(
                payload: payload, records: try group.loadRecords(),
                phoneKey: { try secrets.load(account: SecretAccount.key($0.pairingId)) },
                state: { try group.loadPush($0.pairingId) })
            let id = opened.record.pairingId
            guard let notice = opened.notice else { throw PushFailure.badMessage }
            guard let previews = previewSetting() else {
                return Result(text: PushText.fallback, badge: nil, outcome: "settings")
            }
            let showsRuleText = PushText.showsRuleText(setting: try group.loadSettings().showRuleText, previews: previews)
            let text = PushText.notice(notice, pcName: opened.record.pcName, showsRuleText: showsRuleText)
            let shown = text.category == PushText.ruleCategory
            try group.savePush(PushState.after(opened, shown: shown, previous: previous, now: now), id)
            let badge = WaitingCount.badge(try group.waitingCounts())
            return Result(text: text, badge: badge, outcome: shown ? "shown" : "plain")
        } catch let failure as PushFailure {
            return Result(text: PushText.fallback, badge: nil, outcome: failure.rawValue)
        } catch is GroupFiles.MissingContainer {
            return Result(text: PushText.fallback, badge: nil, outcome: "noAppGroup")
        } catch is KeychainGroup.Failure {
            return Result(text: PushText.fallback, badge: nil, outcome: "noKeychainGroup")
        } catch {
            return Result(text: PushText.fallback, badge: nil, outcome: "storage")
        }
    }

    /// Writes the outcome, the peak memory and the time to `extension-run.json`, which the diagnostics block shows.
    static func record(_ outcome: String) {
        // The notification goes out whether or not this write works, so a failed write only leaves the older record.
        try? GroupFiles.shared().saveExtensionRun(ExtensionRun(outcome: outcome, peakMemory: PeakMemory.read(),
                                                               at: currentTime()))
    }

    /// iOS's preview setting, or nil when iOS did not answer within 2 s.
    private static func previewSetting() -> PreviewSetting? {
        let box = PreviewBox()
        let answered = DispatchSemaphore(value: 0)
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.showPreviewsSetting {
            case .always: box.set(.always)
            case .whenAuthenticated: box.set(.whenAuthenticated)
            default: box.set(.never)
            }
            answered.signal()
        }
        guard answered.wait(timeout: .now() + 2) == .success else { return nil }
        return box.value
    }
}

/// Carries the preview setting out of the settings callback.
private final class PreviewBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: PreviewSetting?

    func set(_ value: PreviewSetting) {
        lock.lock()
        stored = value
        lock.unlock()
    }

    var value: PreviewSetting? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
