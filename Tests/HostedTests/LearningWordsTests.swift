import CryptoKit
import Foundation
@testable import Lastide
import LastideKit
import XCTest

/// Checks U2 and K2 of the learning evidence design (Table 18) on the app's own model, with fake services. A fake PC
/// opens what the phone sends and seals answers through CryptoKit. The words are made up, and no picture is taken.
@MainActor
final class LearningWordsTests: XCTestCase {
    /// The made-up words of this test. Check U3 (`scripts/ci/check_no_words.sh`) searches for them everywhere else.
    static let marker = "Hosted marker words 5Q2X for check U3"

    private var vector: PushVector!
    private var harness: ModelHarness!
    private var record: PairingRecord!
    private var pcKey: Curve25519.KeyAgreement.PrivateKey!
    private var seq: UInt64 = 1_794_992_500_000

    override func setUp() async throws {
        vector = try PushVector()
        harness = try ModelHarness()
        // The vector's pairing, with a PC of schema revision 4.
        record = vector.record
        record.pcSchema = 4
        let keys = try XCTUnwrap(vector.object["keys"] as? [String: Any])
        pcKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: PushVector.hex(keys["pcPrivateKey"]))
        let group = GroupFiles(directory: try temporaryFolder("learning-group"))
        try group.saveRecords([record])
        let secrets = MemorySecrets()
        try secrets.save(vector.phoneKey, account: SecretAccount.key(vector.id))
        try secrets.save(vector.token, account: SecretAccount.token(vector.id))
        let files = try FileStorage(directory: try temporaryFolder("learning-app"))
        try harness.model.load(LiveStores(files: files, group: group, secrets: secrets, oldPairingsURL: nil))
        harness.model.cameToScreen()
        let phone = record.phoneId.base64url
        harness.sockets.deliver(.text(#"{"op":"welcome","v":1,"role":"phone","device":"\#(phone)","features":["mailbox"],"pcOnline":true,"pcLastSeenAt":null,"mailbox":0}"#))
        XCTAssertEqual(harness.model.connection, .open)
        XCTAssertTrue(harness.model.pcOnline)
    }

    private var socket: FakeSocket { harness.sockets.sockets.last! }
    private var info: Data { Data("lastide/v1/message".utf8) + Data([0]) + record.pairingId.bytes }

    /// Opens the phone's newest envelope as the PC does.
    private func lastMessage() throws -> SyncMessage {
        let bytes = try XCTUnwrap(socket.binaries.last)
        let header = try EnvelopeHeader(frame: bytes)
        let phonePublic = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: vector.phoneKey).publicKey
        var recipient = try HPKE.Recipient(privateKey: pcKey, ciphersuite: .Curve25519_SHA256_ChachaPoly, info: info,
                                           encapsulatedKey: header.enc, authenticatedBy: phonePublic)
        return try SyncMessage.decode(recipient.open(bytes.dropFirst(76), authenticating: header.bytes))
    }

    /// Seals one PC message to `key`, the phone key unless a reply key is named, and hands it to the model.
    private func deliver(_ json: String, flags: EnvelopeFlags = [], slot: UInt8 = 0, replyKey: String? = nil) throws {
        let recipientKey = try replyKey.map { try Curve25519.KeyAgreement.PublicKey(rawRepresentation: Base64URL.decode($0, byteCount: 32)) }
            ?? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: vector.phoneKey).publicKey
        var sender = try HPKE.Sender(recipientKey: recipientKey, ciphersuite: .Curve25519_SHA256_ChachaPoly, info: info,
                                     authenticatedBy: pcKey)
        seq += 1
        let header = try EnvelopeHeader(kind: .message, flags: flags, slot: slot, sender: .pc, recipient: record.phoneId,
                                        seq: seq, enc: sender.encapsulatedKey).bytes
        harness.sockets.deliver(.binary(header + (try sender.seal(Data(json.utf8), authenticating: header))))
    }

    private func wordsJSON(_ request: LearningWordsRequest) -> String {
        #"{"type":"learning-words","id":"\#(makeMessageID())","sentAt":1794992651000,"requestId":"\#(request.id)","ref":"\#(request.ref)","state":"words","words":"\#(Self.marker)","nextAt":null}"#
    }

    private let ref = "t-XRqTERYe5h9JUL3fzhiCpg"

    private func askWords() throws -> LearningWordsRequest {
        harness.model.showWords(ref: ref)
        guard case .learningWordsRequest(let request) = try lastMessage() else {
            XCTFail("no words request left")
            throw CocoaError(.featureUnsupported)
        }
        XCTAssertEqual(request.ref, ref)
        return request
    }

    /// The queue snapshot with one draft, so the draft screen may ask for its evidence.
    private func deliverQueue() throws {
        let draft = #"{"id":"d-0001","changedAtStoreVersion":41,"draftKind":"new","text":"Use sentence case in headings.","scope":{"scope":"everyProject","kindOfWork":null,"projectNames":[]},"scopeOptions":[{"id":"s3","scope":"everyProject","kindOfWork":null,"projectNames":[]}],"group":"writing","strength":"preference","agents":["claudeCode"],"desktopOnly":false,"evidence":[{"id":"1","at":1794319200000,"projectName":"northwind-reports","agent":"claudeCode","signal":"typedTurn"}],"evidenceCount":1,"sessionCount":1,"projectCount":1,"leftOutCount":0,"relatedRuleIds":[],"createdAt":1794990600000}"#
        try deliver(#"{"type":"queue","id":"\#(makeMessageID())","sentAt":1794992600000,"schema":4,"storeVersion":42,"omitted":0,"drafts":[\#(draft)]}"#,
                    flags: .mailbox, slot: 1)
        XCTAssertNotNil(harness.model.store.draft(id: "d-0001"))
    }

    private func evidenceJSON(_ request: String) -> String {
        #"{"type":"evidence","id":"\#(makeMessageID())","sentAt":1794992652000,"requestId":"\#(request)","draftId":"d-0001","changedAtStoreVersion":41,"rationale":null,"items":[{"evidenceId":"1","state":"words","words":"\#(Self.marker)"}]}"#
    }

    /// Everything the model holds about the learning screens and the draft screen, as text.
    private var heldText: String {
        String(describing: harness.model.learningWords) + String(describing: harness.model.learningLists)
            + String(describing: harness.model.evidence)
    }

    // MARK: U2

    /// U2: words that arrived, and a request that waits, both go once the scene leaves the active state.
    func testU2TheWordsAndTheReplyKeyGoWhenTheSceneLeavesTheActiveState() throws {
        let request = try askWords()
        XCTAssertEqual(harness.model.waitingReplyKeyCount, 1)
        try deliver(wordsJSON(request), flags: .replyKey, replyKey: request.replyKey)
        XCTAssertEqual(harness.model.learningWords?.phase, .words(Self.marker))
        XCTAssertEqual(harness.model.waitingReplyKeyCount, 0, "the key opened its one answer")
        harness.model.sceneLeftActive()
        XCTAssertNil(harness.model.learningWords)
        XCTAssertFalse(heldText.contains(Self.marker))

        _ = try askWords()
        XCTAssertEqual(harness.model.waitingReplyKeyCount, 1)
        harness.model.sceneLeftActive()
        XCTAssertEqual(harness.model.waitingReplyKeyCount, 0, "a waiting reply key goes too")
        XCTAssertNil(harness.model.learningWords)
    }

    /// U2 on the draft screen: its evidence words and its key go too, and the screen asks again on return.
    func testU2TheDraftScreenDropsItsWordsWhenTheSceneLeavesTheActiveState() throws {
        try deliverQueue()
        harness.model.openEvidence(draftID: "d-0001")
        guard case .evidenceRequest(let request) = try lastMessage() else { return XCTFail("no evidence request left") }
        try deliver(evidenceJSON(request.id), flags: .replyKey, replyKey: request.replyKey)
        XCTAssertEqual(harness.model.evidence?.evidence?.items.first?.words, Self.marker)
        harness.model.openEvidence(draftID: "d-0001")
        XCTAssertEqual(harness.model.waitingReplyKeyCount, 1)
        harness.model.sceneLeftActive()
        XCTAssertNil(harness.model.evidence)
        XCTAssertEqual(harness.model.waitingReplyKeyCount, 0)
        XCTAssertFalse(heldText.contains(Self.marker))
        let generation = harness.model.screenGeneration
        harness.model.cameToScreen()
        XCTAssertEqual(harness.model.screenGeneration, generation + 1, "each open screen asks again")
    }

    /// Lists go too, and the list's screen asks for its first page again on return.
    func testU2ListsGoWhenTheSceneLeavesTheActiveState() throws {
        let subject = LearningSubject.repeatWeek(weekStart: "2026-11-16")
        harness.model.openList(subject)
        guard case .learningRequest(let request) = try lastMessage() else { return XCTFail("no learning request left") }
        XCTAssertEqual(request.from, 0)
        let row = #"{"rowType":"turn","ref":"\#(ref)","at":1794925200000,"projectName":"northwind-reports","agent":"claudeCode","commentLabel":null,"signal":"typedTurn","category":"writing","kindScore":0.83,"scopeScore":0.61,"questionVersion":2,"counted":true,"countedAt":1794925860000,"group":null,"violations":[]}"#
        try deliver(#"{"type":"learning-page","id":"\#(makeMessageID())","sentAt":1794992641000,"requestId":"\#(request.id)","subject":{"kind":"repeatWeek","weekStart":"2026-11-16"},"state":"ok","storeVersion":44,"asOf":1794992640700,"value":1,"total":1,"leftOut":{"untraced":0,"older":0,"afterThisWeek":0},"from":0,"next":null,"listHash":"-SZtyharSXT6tsHqlP-iHg","thresholds":{"kind":0.4,"coverage":0.7,"groupReady":0.5,"groupWait":0.3},"head":null,"rows":[\#(row)]}"#)
        XCTAssertEqual(harness.model.learningLists[subject]?.phase, .shown)
        XCTAssertEqual(harness.model.learningLists[subject]?.rows.count, 1)
        harness.model.sceneLeftActive()
        XCTAssertTrue(harness.model.learningLists.isEmpty)
        let sent = socket.binaries.count
        harness.model.cameToScreen()
        harness.model.openList(subject)
        XCTAssertEqual(socket.binaries.count, sent + 1, "the list asks again")
        guard case .learningRequest(let again) = try lastMessage() else { return XCTFail("no second request") }
        XCTAssertEqual(again.from, 0)
        XCTAssertNil(again.listHash)
    }

    // MARK: K2

    /// K2: a draft's evidence answer leaves the reply key of an open learning row, whose words then still open.
    func testK2ADraftsEvidenceLeavesTheReplyKeyOfAnOpenLearningRow() throws {
        try deliverQueue()
        let words = try askWords()
        harness.model.openEvidence(draftID: "d-0001")
        guard case .evidenceRequest(let evidence) = try lastMessage() else { return XCTFail("no evidence request left") }
        XCTAssertEqual(harness.model.waitingReplyKeyCount, 2)
        try deliver(evidenceJSON(evidence.id), flags: .replyKey, replyKey: evidence.replyKey)
        XCTAssertNotNil(harness.model.evidence?.evidence)
        XCTAssertEqual(harness.model.waitingReplyKeyCount, 1, "the learning row's key stays")
        try deliver(wordsJSON(words), flags: .replyKey, replyKey: words.replyKey)
        XCTAssertEqual(harness.model.learningWords?.phase, .words(Self.marker))
        harness.model.closeEvidence()
        XCTAssertEqual(harness.model.learningWords?.phase, .words(Self.marker), "closing the draft screen leaves the row")
        harness.model.closeWords()
        XCTAssertNil(harness.model.learningWords)
    }

    /// A PC that goes offline takes the lists and the words with it, and Show My Words then reads the offline line.
    func testThePCGoingOfflineDropsTheWordsAndItsKey() throws {
        _ = try askWords()
        harness.sockets.deliver(.text(#"{"op":"presence","device":"\#(DeviceID.pc.base64url)","online":false}"#))
        XCTAssertFalse(harness.model.pcOnline)
        XCTAssertEqual(harness.model.learningWords?.phase, .offline)
        XCTAssertEqual(harness.model.waitingReplyKeyCount, 0)
    }
}
