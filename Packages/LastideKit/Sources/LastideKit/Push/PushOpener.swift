import Crypto
import Foundation

/// Why the phone gave up on one push (design section 6.4). The extension writes the raw value into
/// `extension-run.json` as its outcome code, so each code names the step that failed.
public enum PushFailure: String, Error, Sendable, CaseIterable {
    /// Step 1: `lastide.v` is not 1, or `lastide.e` is not canonical base64url of 92 to 2,800 bytes.
    case payload
    /// Step 2: not kind 4, flags 0, the expected slot and the PC as sender.
    case header
    /// Step 3: no pairing record has the header's recipient as its phone id.
    case unknownPairing
    /// Step 4: the Keychain holds no key for that pairing.
    case noKey
    /// Step 5: the envelope did not open in Auth mode with the PC key and `INFO_PUSH`.
    case openFailed
    /// Step 6: `seq` is not above `lastPushSeq`.
    case replay
    /// Step 7: the plaintext is not the message type of its slot, or breaks protocol section 7.3.
    case badMessage
}

/// One kind 4 envelope that opened and passed the checks of design section 6.4.
public struct OpenedPush: Sendable {
    /// The pairing whose phone id the header names.
    public let record: PairingRecord
    /// The header's `seq`.
    public let seq: UInt64
    /// A `notice` in slot 0, or a `count-update` in slot 1.
    public let message: SyncMessage

    /// The notice, when the envelope held one.
    public var notice: Notice? {
        if case .notice(let notice) = message { return notice }
        return nil
    }

    /// The count update, when the envelope held one.
    public var countUpdate: CountUpdate? {
        if case .countUpdate(let update) = message { return update }
        return nil
    }
}

/// Opens the kind 4 envelope that the relay puts in `lastide.e` (design sections 6.4 to 6.6, protocol 9.4).
/// The notification service extension, the action handler and the count update handler all call it.
public enum PushOpener {
    /// The slot of an alert notice.
    public static let noticeSlot: UInt8 = 0
    /// The slot of a count update.
    public static let countUpdateSlot: UInt8 = 1

    /// Step 1: reads `lastide.v`, which must be 1, and the envelope in `lastide.e`, which must be canonical base64url
    /// of 92 to 2,800 bytes.
    public static func envelope(from payload: [AnyHashable: Any]) throws -> Data {
        guard let lastide = payload["lastide"] as? [String: Any],
              let version = lastide["v"] as? Int, version == 1,
              let text = lastide["e"] as? String,
              let bytes = try? Base64URL.decode(text),
              bytes.count >= LastideProtocol.smallestEnvelope, bytes.count <= LastideProtocol.largestPushEnvelope
        else { throw PushFailure.payload }
        return bytes
    }

    /// Steps 2 to 5 and 7: checks the header, finds the pairing, reads its key and opens the envelope. `phoneKey`
    /// returns the 32 raw bytes of the pairing's phone key, or nil when the Keychain holds none.
    public static func open(_ envelope: Data, slot: UInt8, records: [PairingRecord],
                            phoneKey: (PairingRecord) throws -> Data?,
                            revision: Int = LastideProtocol.schemaRevision) throws -> OpenedPush {
        guard envelope.count <= LastideProtocol.largestPushEnvelope else { throw PushFailure.payload }
        let header: EnvelopeHeader
        do { header = try EnvelopeHeader(frame: envelope) } catch { throw PushFailure.header }
        guard header.kind == .push, header.flags.isEmpty, header.slot == slot, header.sender == .pc else {
            throw PushFailure.header
        }
        guard let record = records.first(where: { $0.phoneId == header.recipient }) else { throw PushFailure.unknownPairing }
        let keyBytes: Data?
        do { keyBytes = try phoneKey(record) } catch { throw PushFailure.noKey }
        guard let keyBytes, let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: keyBytes) else {
            throw PushFailure.noKey
        }
        let plaintext: Data
        do {
            var recipient = try HPKE.Recipient(privateKey: key, ciphersuite: LastideProtocol.ciphersuite,
                                               info: Labels.pushInfo(record.pairingId), encapsulatedKey: header.enc,
                                               authenticatedBy: try record.pcPublicKey())
            plaintext = try recipient.open(envelope.dropFirst(LastideProtocol.headerSize), authenticating: header.bytes)
        } catch {
            throw PushFailure.openFailed
        }
        let message: SyncMessage
        do { message = try SyncMessage.decode(plaintext, revision: revision) } catch { throw PushFailure.badMessage }
        let expected: MessageType = slot == noticeSlot ? .notice : .countUpdate
        guard message.type == expected else { throw PushFailure.badMessage }
        return OpenedPush(record: record, seq: header.seq, message: message)
    }

    /// Steps 1 to 7 for the notification service extension: an alert notice in slot 0 whose `seq` lies above
    /// `lastPushSeq` of the pairing's push state. `state` reads that pairing's `push/<pairing id>.json`. Returns the
    /// notice and the state it read, which the extension writes again after step 10.
    public static func openNotice(payload: [AnyHashable: Any], records: [PairingRecord],
                                  phoneKey: (PairingRecord) throws -> Data?,
                                  state: (PairingRecord) throws -> PushState?) throws -> (OpenedPush, PushState?) {
        let opened = try open(envelope(from: payload), slot: noticeSlot, records: records, phoneKey: phoneKey)
        let previous = try state(opened.record)
        guard opened.seq > previous?.lastPushSeq ?? 0 else { throw PushFailure.replay }
        return (opened, previous)
    }
}

/// The title, subtitle, body and category of one notification, as the extension sets them and as iOS hands them to
/// the app with an action.
public struct NotificationText: Hashable, Sendable {
    public var title: String
    public var subtitle: String
    public var body: String
    public var category: String

    public init(title: String, subtitle: String, body: String, category: String) {
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.category = category
    }
}

/// iOS's lock-screen preview setting, as `UNNotificationSettings.showPreviewsSetting` reports it.
public enum PreviewSetting: Sendable, CaseIterable {
    case always, whenAuthenticated, never
}

/// The fixed texts and categories of phase 7 notifications (design sections 6.4 and 6.5).
public enum PushText {
    /// The category that offers Approve, Delete and Open. Only the extension sets it, after a good open.
    public static let ruleCategory = "PROPOSED_RULE"
    /// The category that offers Open only. The relay's alert names it.
    public static let plainCategory = "LASTIDE_PLAIN"
    /// The action ids of design Table 15.
    public static let approveAction = "APPROVE"
    public static let deleteAction = "DELETE"
    public static let openAction = "OPEN"
    /// The title of every notice that does not show the rule text.
    public static let appName = "Lastide"
    /// What the lock screen shows while previews are hidden.
    public static let hiddenPreviewsPlaceholder = "A rule waits for your review."
    /// The text of a failed step, a replay or the end of the extension's time.
    public static let fallback = NotificationText(title: appName, subtitle: "", body: "Open Lastide to see what changed.",
                                                  category: plainCategory)
    /// The local notice when the action handler refused to act.
    public static let actionRefused = "Lastide did not act on this notice. Open Lastide to review the rule."
    /// The local notice when Approve or Delete arrived while the phone was locked, as from a paired Apple Watch.
    public static let actionLocked = "Lastide acts on a notification only while iPhone is unlocked. Open Lastide to review the rule."
    /// The question the app asks before it asks iOS for notification permission.
    public static let permissionQuestion = "Get a notification when a rule waits for your review?"

    /// The widget's line: "1 rule waits", "{n} rules wait" or "No rules wait" (design section 6.7).
    public static func widgetLine(_ count: Int) -> String {
        switch count {
        case 0: return "No rules wait"
        case 1: return "1 rule waits"
        default: return "\(count) rules wait"
        }
    }

    /// The widget's line without a pairing.
    public static let widgetPairPrompt = "Pair a PC in Lastide"

    /// The widget's time line, for example "Updated 14:05".
    public static func widgetUpdated(_ time: String) -> String { "Updated \(time)" }

    /// "A rule waits for your review.", or "{n} rules wait for your review." for 2 or more.
    public static func waiting(_ count: Int) -> String {
        count >= 2 ? "\(count) rules wait for your review." : "A rule waits for your review."
    }

    /// Whether the rule text may show (design section 6.8, decision D7). With iOS's "When Unlocked" previews, iOS hides
    /// the text until the person unlocks the phone, so the first switch decides. With "Always" previews the text would
    /// show on a locked phone, so it also needs the switch "Show rule text while iPhone is locked". It never shows while
    /// previews are off.
    public static func showsRuleText(_ settings: GroupSettings, previews: PreviewSetting) -> Bool {
        switch previews {
        case .whenAuthenticated: return settings.showRuleText
        case .always: return settings.showRuleText && settings.showRuleTextWhenLocked
        case .never: return false
        }
    }

    /// The subtitle of a notice that shows its draft: the draft's scope. So a rule for every project never looks like
    /// a rule for one project on the lock screen (design section 6.4, step 10).
    public static func scopeLine(_ scope: Scope) -> String {
        switch scope.kind {
        case .everyProject: return "All projects"
        case .kindOfWork: return "Kind of work: " + (scope.kindOfWork ?? "")
        case .thisProject:
            return (scope.projectNames.count == 1 ? "Project: " : "Projects: ") + scope.projectNames.joined(separator: ", ")
        }
    }

    /// Steps 10 and 11 of design section 6.4: the PC's name, the draft's scope and the draft text with Approve and
    /// Delete, or the plain waiting text. The PC sends a draft only when its whole text fits the notice, so the text
    /// that shows is the text an approval applies (protocol section 7.3).
    public static func notice(_ notice: Notice, pcName: String, showsRuleText: Bool) -> NotificationText {
        if showsRuleText, let draft = notice.draft {
            return NotificationText(title: pcName, subtitle: scopeLine(draft.scope), body: draft.text, category: ruleCategory)
        }
        return NotificationText(title: appName, subtitle: "", body: waiting(notice.queueCount), category: plainCategory)
    }

    /// The local notice when a lock-screen decision did not reach the relay (design 6.5, step 10).
    public static func actionNotSent(_ action: DecisionAction) -> String {
        action == .delete ? "Your delete did not reach the relay. Open Lastide to send it."
            : "Your approval did not reach the relay. Open Lastide to send it."
    }
}

/// Why the action handler refused a lock-screen Approve or Delete (design 6.5, steps 3 and 4).
public enum NoticeActionRefusal: String, Error, Sendable, CaseIterable {
    /// The notice holds no draft.
    case noDraft
    /// The header's `seq` is not the `shownSeq` the extension wrote for that pairing.
    case notShown
    /// The shown title, subtitle, body or category differs from what the extension sets.
    case textDiffers
}

/// The guard of a lock-screen action (design 6.5, steps 3 and 4). It trusts only the envelope the app opened again,
/// the `shownSeq` the extension wrote, and a shown title, subtitle, body and category equal to what the extension sets.
public enum NoticeActionGuard {
    /// Returns the notice to act on, or throws `NoticeActionRefusal`.
    public static func check(_ opened: OpenedPush, shownSeq: UInt64?, shown: NotificationText) throws -> Notice {
        guard let notice = opened.notice, notice.draft != nil else { throw NoticeActionRefusal.noDraft }
        guard let shownSeq, shownSeq == opened.seq else { throw NoticeActionRefusal.notShown }
        // The text the extension sets with Approve and Delete: the PC's name, the scope and the whole draft text.
        let expected = PushText.notice(notice, pcName: opened.record.pcName, showsRuleText: true)
        guard shown == expected else { throw NoticeActionRefusal.textDiffers }
        return notice
    }
}
