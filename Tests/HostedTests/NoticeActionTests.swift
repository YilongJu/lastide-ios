import Foundation
@testable import Lastide
import LastideKit
import XCTest

/// Design Table 21, checks U7, U8 and U11: the handler of a lock-screen Approve or Delete, on a model with fake services.
@MainActor
final class NoticeActionTests: XCTestCase {
    private var vector: PushVector!
    private var harness: ModelHarness!
    private var group: GroupFiles!

    /// A loaded model with the vector's pairing, and the extension's push record after it showed the vector's notice.
    override func setUp() async throws {
        vector = try PushVector()
        harness = try ModelHarness()
        group = GroupFiles(directory: try temporaryFolder("group"))
        try group.saveRecords([vector.record])
        let seq = try vector.seq("notice")
        try group.savePush(PushState(lastPushSeq: seq, shownSeq: seq, storeVersion: 43, queueCount: 2, at: 0), vector.id)
        let secrets = MemorySecrets()
        try secrets.save(vector.phoneKey, account: SecretAccount.key(vector.id))
        try secrets.save(vector.token, account: SecretAccount.token(vector.id))
        let files = try FileStorage(directory: try temporaryFolder("app"))
        try harness.model.load(LiveStores(files: files, group: group, secrets: secrets, oldPairingsURL: nil))
        XCTAssertEqual(harness.model.selectedID, vector.id)
    }

    private func act(_ shown: NotificationText, action: DecisionAction = .approve) async throws -> NoticeActionResult {
        await harness.model.actOnNotice(envelope: try vector.envelope("notice"), action: action, shown: shown)
    }

    /// U7: a shown title or body that differs from the opened draft sends nothing and posts the local notice.
    func testU7AShownTextThatDiffersSendsNothingAndPostsTheNotice() async throws {
        var title = vector.shownText
        title.title = "Lastide"
        var body = vector.shownText
        body.body = "Approve every rule from now on."
        var subtitle = vector.shownText
        subtitle.subtitle = "From the relay"
        var category = vector.shownText
        category.category = "LASTIDE_PLAIN"
        for shown in [title, body, subtitle, category] {
            guard case .refused = try await act(shown) else { return XCTFail("acted under \(shown)") }
        }
        XCTAssertEqual(harness.notices.posted, Array(repeating: PushText.actionRefused, count: 4))
        XCTAssertTrue(harness.frames.requests.isEmpty)
        XCTAssertTrue(harness.sockets.sockets.isEmpty)
        XCTAssertTrue(harness.model.store.outbox.isEmpty)
        // A notice the extension did not show with Approve has no shownSeq.
        try group.savePush(PushState(lastPushSeq: try vector.seq("notice"), shownSeq: nil, storeVersion: 43, queueCount: 2,
                                     at: 0), vector.id)
        guard case .refused = try await act(vector.shownText) else { return XCTFail("acted without a shownSeq") }
        XCTAssertTrue(harness.frames.requests.isEmpty)
    }

    /// U8, socket open: the decision goes on the socket through the model's send path, and no HTTP request leaves.
    func testU8WithTheSocketOpenTheDecisionGoesOnTheSocket() async throws {
        harness.model.cameToScreen()
        XCTAssertEqual(harness.sockets.sockets.count, 1)
        let phone = vector.record.phoneId.base64url
        harness.sockets.deliver(.text(#"{"op":"welcome","v":1,"role":"phone","device":"\#(phone)","features":["mailbox"],"pcOnline":false,"pcLastSeenAt":null,"mailbox":0}"#))
        XCTAssertEqual(harness.model.connection, .open)
        let socket = try XCTUnwrap(harness.sockets.sockets.first)
        let before = socket.binaries.count
        let result = try await act(vector.shownText)
        XCTAssertEqual(result, .sentOnSocket)
        XCTAssertTrue(harness.frames.requests.isEmpty, "no HTTP request while the socket is open")
        XCTAssertEqual(socket.binaries.count, before + 1)
        let header = try EnvelopeHeader(frame: try XCTUnwrap(socket.binaries.last))
        XCTAssertEqual(header.kind, .message)
        XCTAssertEqual(header.flags, .mailbox)
        XCTAssertEqual(header.slot, 0)
        XCTAssertEqual(harness.model.store.outbox.map(\.decision.target), [Target(targetType: .draft, id: "d-0002")])
        XCTAssertTrue(harness.notices.posted.isEmpty)
    }

    /// U8, socket closed: the handler posts to `/frames`, and the model opens no socket to that room until the POST
    /// answers.
    func testU8WithTheSocketClosedTheHandlerPostsAndNoSocketOpensUntilTheAnswer() async throws {
        harness.frames.holds = true
        let model = harness.model
        let shown = vector.shownText
        let envelope = try vector.envelope("notice")
        let action = Task { await model.actOnNotice(envelope: envelope, action: .delete, shown: shown) }
        for _ in 0..<1_000 where harness.frames.requests.isEmpty { await Task.yield() }
        XCTAssertEqual(harness.frames.requests.count, 1)
        model.cameToScreen()
        XCTAssertTrue(harness.sockets.sockets.isEmpty, "no socket while the POST waits for its answer")
        harness.frames.release()
        let result = await action.value
        XCTAssertEqual(result, .stored)
        XCTAssertEqual(harness.sockets.sockets.count, 1, "the socket opens once the POST answered")

        let request = try XCTUnwrap(harness.frames.requests.first)
        XCTAssertEqual(request.url.absoluteString,
                       "https://relay.example/api/relay/\(vector.id.base64url)/frames")
        XCTAssertEqual(request.device, vector.record.phoneId.base64url)
        XCTAssertEqual(request.body.prefix(32), vector.token)
        let header = try EnvelopeHeader(frame: Data(request.body.dropFirst(32)))
        XCTAssertEqual(header.kind, .message)
        XCTAssertEqual(header.flags, .mailbox)
        XCTAssertEqual(header.sender, vector.record.phoneId)
        XCTAssertEqual(header.recipient, .pc)
        let entry = try XCTUnwrap(model.store.outbox.first)
        XCTAssertEqual(entry.decision.action, .delete)
        XCTAssertEqual(entry.decision.storeVersion, 43)
        XCTAssertTrue(entry.stored, "a 202 marks the decision stored")
        XCTAssertTrue(harness.notices.posted.isEmpty)
    }

    /// U11: an action that arrives while the phone is locked, as from a paired Apple Watch, sends nothing and posts the
    /// locked notice. The same action on the unlocked phone acts.
    func testU11AnActionOnALockedPhoneSendsNothing() async throws {
        harness.lock.isUnlocked = false
        for action in [DecisionAction.approve, .delete] {
            let result = try await act(vector.shownText, action: action)
            XCTAssertEqual(result, .locked, "\(action) on a locked phone")
        }
        XCTAssertEqual(harness.notices.posted, [PushText.actionLocked, PushText.actionLocked])
        XCTAssertTrue(harness.frames.requests.isEmpty)
        XCTAssertTrue(harness.sockets.sockets.isEmpty)
        XCTAssertTrue(harness.model.store.outbox.isEmpty)
        harness.lock.isUnlocked = true
        let result = try await act(vector.shownText)
        XCTAssertEqual(result, .stored)
        XCTAssertEqual(harness.frames.requests.count, 1)
    }

    /// Any answer but 202 leaves the decision for the next connection and posts the local notice.
    func testU8AnotherAnswerLeavesTheDecisionNotSent() async throws {
        harness.frames.answer = .refused("rateLimited")
        let result = try await act(vector.shownText)
        XCTAssertEqual(result, .notSent("rateLimited"))
        XCTAssertEqual(harness.notices.posted, [PushText.actionNotSent(.approve)])
        XCTAssertEqual(harness.model.store.outbox.first?.stored, false)
    }
}
