import Crypto
import Foundation
@testable import LastideKit
import XCTest

/// The phone's push and attestation code against the push vector of protocol section 10.5 (design Table 20, S1 to S9).
final class PushTests: XCTestCase {
    private var vector: [String: Any] = [:]
    private var pcKey: Curve25519.KeyAgreement.PrivateKey!
    private var phoneKey: Curve25519.KeyAgreement.PrivateKey!
    private var record: PairingRecord!

    override func setUpWithError() throws {
        vector = try XCTUnwrap(Vectors.object("lastide-push-v1") as? [String: Any])
        let keys = try XCTUnwrap(vector["keys"] as? [String: Any])
        pcKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: hex(keys["pcPrivateKey"]))
        phoneKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: hex(keys["phonePrivateKey"]))
        let ids = try XCTUnwrap(vector["ids"] as? [String: Any])
        record = PairingRecord(pairingId: try PairingID(bytes: hex(ids["pairingId"])), relayOrigin: relayOrigin,
                               pcKey: Base64URL.encode(pcKey.publicKey.rawRepresentation), pcName: "My PC", pcSchema: 3,
                               phoneId: try DeviceID(bytes: hex(ids["phoneId"])), pairedAt: sampleTime, pcLastSeenAt: nil,
                               lastSentSeq: 1, lastRecvSeq: 1, features: [.mailbox, .push])
    }

    private func entry(_ name: String) throws -> [String: Any] { try XCTUnwrap(vector[name] as? [String: Any]) }

    private func payload(_ e: String) -> [AnyHashable: Any] { ["lastide": ["v": 1, "e": e] as [String: Any]] }

    private func key(_ record: PairingRecord) -> Data? { phoneKey.rawRepresentation }

    /// Seals a plaintext as the PC with the vector's keys, so only the named field differs from a good push.
    private func seal(_ plaintext: String, kind: EnvelopeKind = .push, slot: UInt8 = 0, seq: UInt64 = 1_794_992_600_000)
        throws -> Data {
        try sealEnvelope(kind: kind, flags: [], slot: slot, sender: .pc, recipient: record.phoneId, seq: seq,
                         recipientKey: phoneKey.publicKey, senderKey: pcKey, info: Labels.pushInfo(record.pairingId),
                         plaintext: Data(plaintext.utf8)).bytes
    }

    private func noticeText() throws -> String { try XCTUnwrap(entry("notice")["plaintext"] as? String) }

    private func openNotice(_ envelope: Data, state: PushState? = nil, records: [PairingRecord]? = nil,
                            phoneKey: ((PairingRecord) throws -> Data?)? = nil) throws -> OpenedPush {
        try PushOpener.openNotice(payload: payload(Base64URL.encode(envelope)), records: records ?? [record],
                                  phoneKey: phoneKey ?? key, state: { _ in state }).0
    }

    private func failure(_ body: () throws -> Void) -> PushFailure? {
        do {
            try body()
            return nil
        } catch let failure as PushFailure {
            return failure
        } catch {
            XCTFail("not a PushFailure: \(error)")
            return nil
        }
    }

    // MARK: S1

    func testS1TheVectorNoticeOpensWithThePhoneKeyAndAFlippedHeaderBitRefuses() throws {
        let notice = try entry("notice")
        let envelope = try PushOpener.envelope(from: payload(try XCTUnwrap(notice["e"] as? String)))
        XCTAssertEqual(envelope, try hex(notice["envelope"]))
        let opened = try PushOpener.open(envelope, slot: PushOpener.noticeSlot, records: [record], phoneKey: key)
        XCTAssertEqual(opened.seq, 1_794_992_520_000)
        XCTAssertEqual(opened.record.pairingId, record.pairingId)
        let message = try XCTUnwrap(opened.notice)
        XCTAssertEqual(message, try XCTUnwrap(try SyncMessage.decode(Data(noticeText().utf8)).notice))
        XCTAssertEqual(message.storeVersion, 43)
        XCTAssertEqual(message.queueCount, 2)
        XCTAssertEqual(message.draft?.id, "d-0002")
        XCTAssertEqual(message.draft?.text, "Name each branch after its ticket.")
        var refused = 0
        for bit in 0..<(LastideProtocol.headerSize * 8) {
            var flipped = envelope
            flipped[bit / 8] ^= UInt8(1 << (bit % 8))
            XCTAssertNotNil(failure { _ = try PushOpener.open(flipped, slot: 0, records: [self.record], phoneKey: self.key) },
                            "bit \(bit)")
            refused += 1
        }
        XCTAssertEqual(refused, 608)
    }

    // MARK: S2

    func testS2SixInputsGiveTheFallback() throws {
        let good = try hex(entry("notice")["envelope"])
        XCTAssertNoThrow(try openNotice(good))
        let state = PushState(lastPushSeq: 1_794_992_520_000, shownSeq: nil, storeVersion: 43, queueCount: 2, at: sampleTime)
        XCTAssertEqual(failure { _ = try self.openNotice(good, state: state) }, .replay, "a replay")
        var other = record!
        other.phoneId = DeviceID.random()
        XCTAssertEqual(failure { _ = try self.openNotice(good, records: [other]) }, .unknownPairing, "a wrong recipient")
        XCTAssertEqual(failure { _ = try self.openNotice(try self.seal(self.noticeText(), kind: .message)) }, .header, "kind 3")
        XCTAssertEqual(failure { _ = try self.openNotice(try self.seal(self.noticeText(), slot: 1)) }, .header, "slot 1")
        let oversized = try seal(String(repeating: "x", count: 2_801 - 92))
        XCTAssertEqual(oversized.count, 2_801)
        XCTAssertEqual(failure { _ = try self.openNotice(oversized) }, .payload, "2,801 bytes")
        let countUpdate = try XCTUnwrap(entry("countUpdate")["plaintext"] as? String)
        XCTAssertEqual(failure { _ = try self.openNotice(try self.seal(countUpdate)) }, .badMessage, "count-update in slot 0")
        // The largest size passes step 1 and fails only at a later step.
        let largest = try seal(String(repeating: "x", count: 2_800 - 92))
        XCTAssertEqual(failure { _ = try self.openNotice(largest) }, .badMessage, "2,800 bytes of junk")
        XCTAssertEqual(failure { _ = try PushOpener.envelope(from: ["lastide": ["v": 2, "e": "AAAA"] as [String: Any]]) },
                       .payload, "version 2")
        XCTAssertEqual(failure { _ = try PushOpener.envelope(from: [:]) }, .payload, "no lastide key")
        let padded = Base64URL.encode(good) + "="
        XCTAssertEqual(failure { _ = try PushOpener.envelope(from: self.payload(padded)) }, .payload, "not canonical")
        XCTAssertEqual(failure { _ = try self.openNotice(good, phoneKey: { _ in nil }) }, .noKey, "no key in the Keychain")
        XCTAssertEqual(PushText.fallback, NotificationText(title: "Lastide", subtitle: "", body: "Open Lastide to see what changed.",
                                                           category: "LASTIDE_PLAIN"))
    }

    // MARK: S3

    func testS3TheTextsAndCategoriesOfTheExtension() throws {
        let notice = try XCTUnwrap(try SyncMessage.decode(Data(noticeText().utf8)).notice)
        XCTAssertEqual(PushText.ruleCategory, "PROPOSED_RULE")
        XCTAssertEqual(PushText.plainCategory, "LASTIDE_PLAIN")
        XCTAssertEqual(PushText.hiddenPreviewsPlaceholder, "A rule waits for your review.")
        XCTAssertEqual(PushText.notice(notice, pcName: "My PC", showsRuleText: true),
                       NotificationText(title: "My PC", subtitle: "", body: "Name each branch after its ticket.",
                                        category: "PROPOSED_RULE"))
        XCTAssertEqual(PushText.notice(notice, pcName: "My PC", showsRuleText: false),
                       NotificationText(title: "Lastide", subtitle: "", body: "2 rules wait for your review.",
                                        category: "LASTIDE_PLAIN"))
        var withoutDraft = notice
        withoutDraft.draft = nil
        withoutDraft.queueCount = 1
        XCTAssertEqual(PushText.notice(withoutDraft, pcName: "My PC", showsRuleText: true),
                       NotificationText(title: "Lastide", subtitle: "", body: "A rule waits for your review.",
                                        category: "LASTIDE_PLAIN"))
        XCTAssertEqual(PushText.waiting(0), "A rule waits for your review.")
        XCTAssertEqual(PushText.waiting(1), "A rule waits for your review.")
        XCTAssertEqual(PushText.waiting(7), "7 rules wait for your review.")
        XCTAssertTrue(PushText.showsRuleText(setting: true, previews: .always))
        XCTAssertTrue(PushText.showsRuleText(setting: true, previews: .whenAuthenticated))
        XCTAssertFalse(PushText.showsRuleText(setting: true, previews: .never))
        XCTAssertFalse(PushText.showsRuleText(setting: false, previews: .always))
        XCTAssertEqual(PushText.actionRefused, "Lastide did not act on this notice. Open Lastide to review the rule.")
        XCTAssertEqual(PushText.actionNotSent(.approve), "Your approval did not reach the relay. Open Lastide to send it.")
        XCTAssertEqual(PushText.actionNotSent(.delete), "Your delete did not reach the relay. Open Lastide to send it.")
        XCTAssertEqual(GroupSettings.standard.showRuleText, true, "decision D7: the rule text shows by default")
    }

    /// The widget texts of design section 6.7.
    func testTheWidgetTexts() {
        XCTAssertEqual(PushText.widgetLine(0), "No rules wait")
        XCTAssertEqual(PushText.widgetLine(1), "1 rule waits")
        XCTAssertEqual(PushText.widgetLine(12), "12 rules wait")
        XCTAssertEqual(PushText.widgetPairPrompt, "Pair a PC in Lastide")
        XCTAssertEqual(PushText.widgetUpdated("14:05"), "Updated 14:05")
    }

    // MARK: S4

    func testS4CountUpdateDecodesAtRevisionThreeAndFailsAtRevisionTwo() throws {
        let plaintext = Data(try XCTUnwrap(entry("countUpdate")["plaintext"] as? String).utf8)
        guard case .countUpdate(let update) = try SyncMessage.decode(plaintext, revision: 3) else {
            return XCTFail("not a count-update")
        }
        XCTAssertEqual(update.storeVersion, 44)
        XCTAssertEqual(update.queueCount, 0)
        XCTAssertThrowsError(try SyncMessage.decode(plaintext, revision: 2)) { error in
            XCTAssertEqual((error as? MessageDecodingError)?.code, .unknownType)
        }
        XCTAssertEqual(LastideProtocol.schemaRevision, 3)
        XCTAssertEqual(MessageType.countUpdate.kind, .push)
        XCTAssertEqual(MessageType.countUpdate.slot, 1)
        XCTAssertEqual(MessageType.countUpdate.flags, [])
        XCTAssertEqual(MessageType.countUpdate.firstRevision, 3)
        XCTAssertEqual(MessageType.notice.firstRevision, 1)
        let negative = String(decoding: plaintext, as: UTF8.self).replacingOccurrences(of: #""queueCount":0"#,
                                                                                      with: #""queueCount":-1"#)
        XCTAssertThrowsError(try SyncMessage.decode(Data(negative.utf8)))
        let envelope = try PushOpener.envelope(from: payload(try XCTUnwrap(entry("countUpdate")["e"] as? String)))
        let opened = try PushOpener.open(envelope, slot: PushOpener.countUpdateSlot, records: [record], phoneKey: key)
        XCTAssertEqual(opened.countUpdate, update)
        XCTAssertEqual(opened.seq, 1_794_992_580_000)
        XCTAssertEqual(failure { _ = try PushOpener.open(envelope, slot: 0, records: [self.record], phoneKey: self.key) },
                       .header, "a count update is not an alert notice")
    }

    // MARK: S5

    func testS5TheClientDataIs82BytesAndItsHashMatchesTheVector() throws {
        let attest = try entry("attest")
        let challenge = try hex(attest["challenge"])
        let h1 = try hex(attest["pairRequestHash"])
        let clientData = AttestClientData.bytes(challenge: challenge, pairRequestHash: h1)
        XCTAssertEqual(clientData.count, 82)
        XCTAssertEqual(clientData, try hex(attest["clientData"]))
        XCTAssertEqual(AttestClientData.hash(challenge: challenge, pairRequestHash: h1), try hex(attest["clientDataHash"]))
        let pairing = try XCTUnwrap(Vectors.object("lastide-v1") as? [String: Any])
        let pairRequest = try XCTUnwrap(pairing["pairRequest"] as? [String: Any])
        XCTAssertEqual(h1, try hex(pairRequest["envelopeSha256"]), "h1 is the pair request hash of the Lastide vector")
    }

    // MARK: S6

    func testS6TheFramesBodyIsTheTokenThenTheEnvelope() throws {
        let token = Data((0..<32).map { UInt8($0) })
        let envelope = try hex(entry("notice")["envelope"])
        let request = FramesRequest(record: record, token: token, envelope: envelope)
        XCTAssertEqual(request.url.absoluteString, "https://relay.example/api/relay/NCvG0FBkatktbCilgU7GqA/frames")
        XCTAssertEqual(FramesRequest.deviceHeader, "Lastide-Device")
        XCTAssertEqual(FramesRequest.contentType, "application/octet-stream")
        XCTAssertEqual(request.device, record.phoneId.base64url)
        XCTAssertEqual(request.device.count, 22)
        XCTAssertEqual(request.body.count, 32 + envelope.count)
        XCTAssertEqual(request.body.prefix(32), token)
        XCTAssertEqual(request.body.dropFirst(32), envelope)
        XCTAssertEqual(FramesAnswer(status: 202, body: Data(#"{"stored": true, "seq": 1794992600000}"#.utf8)),
                       .stored(seq: 1_794_992_600_000))
        XCTAssertEqual(FramesAnswer(status: 410, body: Data(#"{"error": "roomGone"}"#.utf8)), .roomGone)
        XCTAssertEqual(FramesAnswer(status: 403, body: Data(#"{"error": "notAttested"}"#.utf8)), .notAttested)
        XCTAssertEqual(FramesAnswer(status: 403, body: Data(#"{"error": "forbidden"}"#.utf8)), .refused("forbidden"))
        XCTAssertEqual(FramesAnswer(status: 429, body: Data(#"{"error": "rateLimited"}"#.utf8)), .refused("rateLimited"))
        XCTAssertEqual(FramesAnswer(status: 202, body: Data("not json".utf8)), .refused("status 202"))
        XCTAssertEqual(FramesAnswer(status: 500, body: Data()), .refused("status 500"))
        XCTAssertTrue(FramesAnswer.stored(seq: 1).isStored)
        XCTAssertFalse(FramesAnswer.roomGone.isStored)
    }

    // MARK: S7

    func testS7TheActionGuardAllowsOnlyTheShownNoticeWithTheExtensionsText() throws {
        let opened = try PushOpener.open(try hex(entry("notice")["envelope"]), slot: 0, records: [record], phoneKey: key)
        let shown = NotificationText(title: "My PC", subtitle: "", body: "Name each branch after its ticket.",
                                     category: "PROPOSED_RULE")
        XCTAssertEqual(try NoticeActionGuard.check(opened, shownSeq: opened.seq, shown: shown).draft?.id, "d-0002")
        func refusal(_ shownSeq: UInt64?, _ text: NotificationText, _ push: OpenedPush? = nil) -> NoticeActionRefusal? {
            do {
                _ = try NoticeActionGuard.check(push ?? opened, shownSeq: shownSeq, shown: text)
                return nil
            } catch let refusal as NoticeActionRefusal {
                return refusal
            } catch {
                XCTFail("not a NoticeActionRefusal: \(error)")
                return nil
            }
        }
        XCTAssertEqual(refusal(nil, shown), .notShown, "no shownSeq")
        XCTAssertEqual(refusal(opened.seq - 1, shown), .notShown, "another shownSeq")
        XCTAssertEqual(refusal(opened.seq + 1, shown), .notShown, "a later shownSeq")
        var text = shown
        text.title = "Lastide"
        XCTAssertEqual(refusal(opened.seq, text), .textDiffers, "another title")
        text = shown
        text.body = "Approve every rule."
        XCTAssertEqual(refusal(opened.seq, text), .textDiffers, "another body")
        text = shown
        text.subtitle = "From the relay"
        XCTAssertEqual(refusal(opened.seq, text), .textDiffers, "a subtitle")
        text = shown
        text.category = "LASTIDE_PLAIN"
        XCTAssertEqual(refusal(opened.seq, text), .textDiffers, "another category")
        let withoutDraft = try noticeText().replacingOccurrences(
            of: #"{"id":"d-0002","changedAtStoreVersion":43,"draftKind":"new","text":"Name each branch after its ticket.","scope":{"scope":"everyProject","kindOfWork":null,"projectNames":[]}}"#,
            with: "null")
        XCTAssertTrue(withoutDraft.hasSuffix(#""draft":null}"#))
        let plain = try PushOpener.open(try seal(withoutDraft), slot: 0, records: [record], phoneKey: key)
        XCTAssertEqual(refusal(plain.seq, shown, plain), .noDraft, "a notice without a draft")
    }

    // MARK: S8

    func testS8TheAppGroupRecordsRoundTripAndTheNewestCountWins() throws {
        let push = PushState(lastPushSeq: 1_794_992_520_000, shownSeq: 1_794_992_520_000, storeVersion: 43, queueCount: 2,
                             at: sampleTime)
        let count = CountState(storeVersion: 44, queueCount: 0, at: sampleTime + 60_000)
        let run = ExtensionRun(outcome: "shown", peakMemory: 9_437_184, at: sampleTime)
        let widget = WidgetPushState(token: "00ff", widgets: 1, at: sampleTime)
        let settings = GroupSettings(showRuleText: false)
        XCTAssertEqual(try GroupRecord.decode(PushState.self, GroupRecord.encode(push)), push)
        XCTAssertEqual(try GroupRecord.decode(CountState.self, GroupRecord.encode(count)), count)
        XCTAssertEqual(try GroupRecord.decode(ExtensionRun.self, GroupRecord.encode(run)), run)
        XCTAssertEqual(try GroupRecord.decode(WidgetPushState.self, GroupRecord.encode(widget)), widget)
        XCTAssertEqual(try GroupRecord.decode(GroupSettings.self, GroupRecord.encode(settings)), settings)
        XCTAssertEqual(String(decoding: try GroupRecord.encode(count), as: UTF8.self),
                       #"{"at":1794992460000,"queueCount":0,"storeVersion":44}"#)
        XCTAssertEqual(WaitingCount.newest(push: push, count: count),
                       WaitingCount(storeVersion: 44, queueCount: 0, at: sampleTime + 60_000), "the higher store version wins")
        let older = CountState(storeVersion: 42, queueCount: 5, at: sampleTime + 120_000)
        XCTAssertEqual(WaitingCount.newest(push: push, count: older)?.queueCount, 2, "a later time does not beat a newer version")
        let tie = CountState(storeVersion: 43, queueCount: 3, at: sampleTime + 1)
        XCTAssertEqual(WaitingCount.newest(push: push, count: tie)?.queueCount, 3, "a tie goes to the later time")
        XCTAssertEqual(WaitingCount.newest(push: push, count: nil)?.queueCount, 2)
        XCTAssertEqual(WaitingCount.newest(push: nil, count: older)?.queueCount, 5)
        XCTAssertNil(WaitingCount.newest(push: nil, count: nil))
        XCTAssertEqual(WaitingCount.badge([WaitingCount(storeVersion: 1, queueCount: 2, at: 0),
                                           WaitingCount(storeVersion: 9, queueCount: 3, at: 0)]), 5)
        XCTAssertEqual(WaitingCount.badge([]), 0)
        let opened = try PushOpener.open(try hex(entry("notice")["envelope"]), slot: 0, records: [record], phoneKey: key)
        let shownState = PushState.after(opened, shown: true, previous: nil, now: sampleTime)
        XCTAssertEqual(shownState, PushState(lastPushSeq: opened.seq, shownSeq: opened.seq, storeVersion: 43, queueCount: 2,
                                             at: sampleTime))
        let plainState = PushState.after(opened, shown: false, previous: PushState(lastPushSeq: 5, shownSeq: 5, storeVersion: 1,
                                                                                   queueCount: 1, at: 0), now: sampleTime)
        XCTAssertEqual(plainState.shownSeq, 5, "a notice shown without actions keeps the earlier shownSeq")
        XCTAssertEqual(plainState.lastPushSeq, opened.seq)
    }

    // MARK: S9

    func testS9DecideFromNoticeBuildsADecisionWithTheNoticesStoreVersion() throws {
        let notice = try XCTUnwrap(try SyncMessage.decode(Data(noticeText().utf8)).notice)
        var store = ReviewStore(cache: ReviewCache(), outbox: [])
        let decision = try store.decideFromNotice(notice, action: .approve, now: sampleTime)
        XCTAssertEqual(decision.target, Target(targetType: .draft, id: "d-0002"))
        XCTAssertEqual(decision.action, .approve)
        XCTAssertEqual(decision.storeVersion, 43)
        XCTAssertNil(decision.text)
        XCTAssertNil(decision.scopeOptionId)
        XCTAssertEqual(decision.decidedAt, sampleTime)
        XCTAssertEqual(store.outbox.map(\.decision), [decision])
        XCTAssertFalse(store.outbox[0].stored)
        XCTAssertEqual(store.status(of: decision.target), .notSent)
        XCTAssertThrowsError(try store.decideFromNotice(notice, action: .delete, now: sampleTime)) { error in
            XCTAssertEqual(error as? ReviewError, .decisionPending)
        }
        var other = ReviewStore(cache: ReviewCache(), outbox: [])
        XCTAssertEqual(try other.decideFromNotice(notice, action: .delete, now: sampleTime).action, .delete)
        XCTAssertThrowsError(try other.decideFromNotice(notice, action: .reject, now: sampleTime))
        var plain = notice
        plain.draft = nil
        var empty = ReviewStore(cache: ReviewCache(), outbox: [])
        XCTAssertThrowsError(try empty.decideFromNotice(plain, action: .approve, now: sampleTime))
        XCTAssertTrue(empty.outbox.isEmpty)
    }

    // MARK: Control frames and the relay's header check

    func testThePushTokenAndAttestFramesAndTheWelcomeChallenge() throws {
        XCTAssertEqual(ControlFrame.pushToken(rid: "p1", type: .alert, token: Data([0x0a, 0xff] + Array(repeating: 0, count: 30)),
                                              environment: .production),
                       #"{"env":"production","op":"push-token","pushType":"alert","rid":"p1","token":"0aff"# +
                       String(repeating: "0", count: 60) + #""}"#)
        XCTAssertEqual(ControlFrame.pushToken(rid: "p2", type: .widgets, token: nil, environment: .sandbox),
                       #"{"env":"sandbox","op":"push-token","pushType":"widgets","rid":"p2","token":null}"#)
        XCTAssertEqual(PushEnvironment(entitlement: "development"), .sandbox)
        XCTAssertEqual(PushEnvironment(entitlement: "production"), .production)
        XCTAssertNil(PushEnvironment(entitlement: "staging"))
        let h1 = Data(repeating: 7, count: 32)
        let frame = ControlFrame.attest(rid: "a1", keyId: "zgSY9YSD+7TaDXssY6WlOPVS1K3Lmk+pFhlcSWE+ZV0=",
                                        attestation: Data([1, 2, 3]), pairRequestHash: h1)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: String])
        XCTAssertEqual(object, ["op": "attest", "rid": "a1", "keyId": "zgSY9YSD+7TaDXssY6WlOPVS1K3Lmk+pFhlcSWE+ZV0=",
                                "attestation": "AQID", "pairRequestHash": Base64URL.encode(h1)])
        let challenge = Base64URL.encode(Data(repeating: 9, count: 32))
        let welcome = #"{"op":"welcome","v":1,"role":"pairing","device":null,"features":["mailbox","push"],"pcOnline":true,"mailbox":0,"attestChallenge":"\#(challenge)"}"#
        guard case .welcome(let parsed) = try ControlFrame.parse(welcome) else { return XCTFail("not a welcome") }
        XCTAssertEqual(parsed.attestChallenge, Data(repeating: 9, count: 32))
        XCTAssertTrue(parsed.features.contains("push"))
        let without = welcome.replacingOccurrences(of: #","attestChallenge":"\#(challenge)""#, with: "")
        guard case .welcome(let plain) = try ControlFrame.parse(without) else { return XCTFail("not a welcome") }
        XCTAssertNil(plain.attestChallenge)
        XCTAssertThrowsError(try ControlFrame.parse(welcome.replacingOccurrences(of: challenge, with: "AAAA")))
    }

    func testTheRelayHeaderCheckTakesKindFourInSlotZeroOrOne() throws {
        let notice = try hex(entry("notice")["envelope"])
        let countUpdate = try hex(entry("countUpdate")["envelope"])
        XCTAssertNil(relayHeaderCheck(notice))
        XCTAssertNil(relayHeaderCheck(countUpdate))
        var slotTwo = notice
        slotTwo[3] = 2
        XCTAssertEqual(relayHeaderCheck(slotTwo), 4400)
        var mailbox = notice
        mailbox[2] = 1
        XCTAssertEqual(relayHeaderCheck(mailbox), 4400)
    }

    func testAPairingRecordKeepsItsAttestKeyIDAndReadsOldRecords() throws {
        var attested = record!
        attested.attestKeyId = "zgSY9YSD+7TaDXssY6WlOPVS1K3Lmk+pFhlcSWE+ZV0="
        let encoded = try JSONEncoder().encode(attested)
        XCTAssertEqual(try JSONDecoder().decode(PairingRecord.self, from: encoded), attested)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        old["attestKeyId"] = nil
        let decoded = try JSONDecoder().decode(PairingRecord.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(decoded.attestKeyId)
        XCTAssertEqual(decoded, record)
    }
}

private extension SyncMessage {
    var notice: Notice? {
        if case .notice(let notice) = self { return notice }
        return nil
    }
}
