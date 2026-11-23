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

/// Steps 1 to 12 of design section 6.4, on the App Group files and the shared Keychain group. `NoticeSteps` in
/// LastideKit holds the steps, so the package tests run them on Linux.
enum NoticeRun {
    static func currentTime() -> Int { Int((Date().timeIntervalSince1970 * 1_000).rounded(.down)) }

    static func run(payload: [AnyHashable: Any], now: Int) -> NoticeOutcome {
        let group: GroupFiles
        do { group = try GroupFiles.shared() } catch is GroupFiles.MissingContainer {
            return NoticeOutcome(text: PushText.fallback, badge: nil, outcome: "noAppGroup")
        } catch {
            return NoticeOutcome(text: PushText.fallback, badge: nil, outcome: "storage")
        }
        let secrets: KeychainStore
        do { secrets = KeychainStore(accessGroup: try KeychainGroup.shared()) } catch is KeychainGroup.Failure {
            return NoticeOutcome(text: PushText.fallback, badge: nil, outcome: "noKeychainGroup")
        } catch {
            return NoticeOutcome(text: PushText.fallback, badge: nil, outcome: "storage")
        }
        let store = NoticeStore(records: { try group.loadRecords() },
                                phoneKey: { try secrets.load(account: SecretAccount.key($0.pairingId)) },
                                loadPush: { try group.loadPush($0) }, savePush: { try group.savePush($0, $1) },
                                settings: { try group.loadSettings() }, waitingCounts: { try group.waitingCounts() })
        return NoticeSteps.run(payload: payload, store: store, previews: previewSetting, now: now)
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
