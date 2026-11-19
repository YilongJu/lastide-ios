import Foundation
@testable import LastideKit
import XCTest

final class ReviewStoreTests: XCTestCase {
    let draft1 = Target(targetType: .draft, id: "d-0001")
    let rule7 = Target(targetType: .rule, id: "r-0007")

    func store(queue: String = queueJSON(storeVersion: 42), library: String = libraryJSON(storeVersion: 42)) throws -> ReviewStore {
        var store = ReviewStore(cache: ReviewCache(), outbox: [])
        store.apply(try decode(queue))
        store.apply(try decode(library))
        return store
    }

    func testSnapshotsReplaceOnEqualOrHigherStoreVersionOnly() throws {
        var store = try self.store()
        store.apply(try decode(queueJSON(storeVersion: 41, drafts: [])))
        XCTAssertEqual(store.drafts.count, 1, "a lower store version is ignored")
        store.apply(try decode(queueJSON(storeVersion: 42, drafts: [draftJSON(id: "d-0002")])))
        XCTAssertEqual(store.drafts.map(\.id), ["d-0002"], "an equal store version replaces")
        store.apply(try decode(queueJSON(storeVersion: 50, drafts: [])))
        XCTAssertEqual(store.drafts.count, 0)
        XCTAssertEqual(store.have, SnapshotVersions(queue: 50, library: 42))
        XCTAssertEqual(ReviewStore(cache: ReviewCache(), outbox: []).have, SnapshotVersions(queue: nil, library: nil))
    }

    func testFiltersBadgeAndOmitted() throws {
        let drafts = [draftJSON(id: "a", kind: "new"), draftJSON(id: "b", kind: "rewrite"), draftJSON(id: "c", kind: "contradiction"),
                      draftJSON(id: "d", kind: "merge")]
        let store = try self.store(queue: queueJSON(storeVersion: 42, drafts: drafts, omitted: 3))
        XCTAssertEqual(store.drafts(.all).map(\.id), ["a", "b", "c", "d"])
        XCTAssertEqual(store.drafts(.new).map(\.id), ["a"])
        XCTAssertEqual(store.drafts(.rewrite).map(\.id), ["b"])
        XCTAssertEqual(store.drafts(.conflict).map(\.id), ["c"])
        XCTAssertEqual(store.badgeCount, 7)
        XCTAssertEqual(ReviewText.moreOnPC(store.omittedDrafts), "3 more on your PC")
        XCTAssertEqual(QueueFilter.allCases.map(\.label), ["All", "New", "Rewrite", "Conflict"])
        XCTAssertEqual(ReviewText.evidenceLine(try XCTUnwrap(store.draft(id: "a"))), "3 corrections, 2 projects")
    }

    func testDecisionGoesFromNotSentToWaitingToApplied() throws {
        var store = try self.store()
        XCTAssertEqual(store.status(of: draft1), .ready)
        let decision = try store.decide(draft1, action: .approve, text: "Use sentence case in every heading.", scopeOptionId: "s3",
                                        now: sampleTime)
        XCTAssertEqual(decision.storeVersion, 42, "the store version of the snapshot that showed the item")
        XCTAssertEqual(store.status(of: draft1), .notSent)
        XCTAssertEqual(store.status(of: draft1).displayText, "Not sent yet")
        XCTAssertFalse(store.status(of: draft1).allowsActions)
        XCTAssertThrowsError(try store.decide(draft1, action: .delete, text: nil, scopeOptionId: nil, now: sampleTime)) {
            XCTAssertEqual($0 as? ReviewError, .decisionPending)
        }
        XCTAssertEqual(store.decisionsToSend(now: sampleTime).map(\.decisionId), [decision.decisionId])
        store.markSent(decisionId: decision.decisionId, seq: 900, now: sampleTime)
        store.apply(relayFrame: .stored(to: .pc, seq: 899))
        XCTAssertEqual(store.status(of: draft1), .notSent, "a stored answer for another seq changes nothing")
        store.apply(relayFrame: .stored(to: .pc, seq: 900))
        XCTAssertEqual(store.status(of: draft1), .waitingForPC)
        XCTAssertEqual(store.status(of: draft1).displayText, "Waiting for your PC")
        XCTAssertEqual(store.decisionsToSend(now: sampleTime + 1), [])
        let rule = #"{"targetType":"rule","rule":\#(ruleJSON(id: "r-0100", version: 43))}"#
        let outcome = store.apply(try decode(acknowledgementJSON(decisionId: decision.decisionId, result: "applied", reason: nil,
                                                                 storeVersion: 43, current: rule)))
        XCTAssertEqual(outcome, .applied(draft1))
        XCTAssertNil(store.draft(id: "d-0001"), "an approved draft leaves the queue")
        XCTAssertEqual(store.rules.first?.id, "r-0100", "the rule the approval made enters the library")
        XCTAssertEqual(store.seenAt(Target(targetType: .rule, id: "r-0100")), 43)
        XCTAssertTrue(store.outbox.isEmpty)
        XCTAssertEqual(store.apply(try decode(acknowledgementJSON(decisionId: decision.decisionId, result: "applied", reason: nil,
                                                                  storeVersion: 43))), .alreadyHandled)
    }

    func testResendsUnstoredDecisionsAndThoseLastSentMoreThanSixDaysAgo() throws {
        var store = try self.store()
        let decision = try store.decide(rule7, action: .turnOff, text: nil, scopeOptionId: nil, now: sampleTime)
        store.markSent(decisionId: decision.decisionId, seq: 7, now: sampleTime)
        store.apply(relayFrame: .dropped(to: .pc, seq: 7, reason: "mailboxFull"))
        XCTAssertEqual(store.outbox.first?.droppedReason, "mailboxFull")
        XCTAssertEqual(store.decisionsToSend(now: sampleTime).count, 1, "a dropped decision waits for the next welcome")
        store.markSent(decisionId: decision.decisionId, seq: 8, now: sampleTime)
        store.apply(relayFrame: .stored(to: .pc, seq: 8))
        XCTAssertEqual(store.decisionsToSend(now: sampleTime + LastideProtocol.outboxResendAgeMs).count, 0)
        XCTAssertEqual(store.decisionsToSend(now: sampleTime + LastideProtocol.outboxResendAgeMs + 1).map(\.decisionId),
                       [decision.decisionId])
    }

    func testEveryRefusalShowsItsSentenceAndStaleVersionShowsTheCurrentItem() throws {
        for reason in RefusalReason.allCases {
            var store = try self.store()
            let decision = try store.decide(draft1, action: .reject, text: nil, scopeOptionId: nil, now: sampleTime)
            let current = reason == .staleVersion
                ? #"{"targetType":"draft","draft":\#(draftJSON(version: 43, text: "Use sentence case in all headings."))}"# : "null"
            let outcome = store.apply(try decode(acknowledgementJSON(decisionId: decision.decisionId, result: "refused",
                                                                     reason: reason.rawValue, storeVersion: 43, current: current)))
            XCTAssertEqual(outcome, .refused(draft1, reason))
            XCTAssertTrue(store.outbox.isEmpty)
            switch reason {
            case .gone:
                XCTAssertNil(store.draft(id: "d-0001"), "a gone item leaves the list")
            case .staleVersion:
                XCTAssertEqual(store.draft(id: "d-0001")?.text, "Use sentence case in all headings.")
                XCTAssertEqual(store.seenAt(draft1), 43)
                XCTAssertEqual(store.status(of: draft1), .refused(.staleVersion, .draft))
                XCTAssertEqual(store.status(of: draft1).displayText, "Your PC changed this one. Review the new version.")
                let again = try store.decide(draft1, action: .approve, text: nil, scopeOptionId: nil, now: sampleTime)
                XCTAssertEqual(again.storeVersion, 43, "the next decision uses the version of the current item")
                XCTAssertEqual(store.status(of: draft1), .notSent)
            default:
                XCTAssertEqual(store.status(of: draft1), .refused(reason, .draft))
                XCTAssertEqual(store.status(of: draft1).displayText, reason.displayText(for: .draft))
            }
        }
        XCTAssertEqual(RefusalReason.expired.displayText(for: .draft), "This change waited too long. Make it again.")
        XCTAssertEqual(RefusalReason.desktopOnly.displayText(for: .draft), "Approve this one on your PC")
        XCTAssertEqual(RefusalReason.desktopOnly.displayText(for: .rule), "Change this one on your PC")
        for reason in RefusalReason.allCases where reason != .desktopOnly {
            XCTAssertEqual(reason.displayText(for: .draft), reason.displayText(for: .rule), "only desktopOnly differs")
        }
    }

    func testPhoneRefusesDecisionsThatTable21DoesNotAllow() throws {
        let drafts = [draftJSON(), draftJSON(id: "d-hook", kind: "hook", desktopOnly: true)]
        let rules = [ruleJSON(), ruleJSON(id: "r-imported", source: "imported")]
        var store = try self.store(queue: queueJSON(storeVersion: 42, drafts: drafts), library: libraryJSON(storeVersion: 42, rules: rules))
        func refused(_ target: Target, _ action: DecisionAction, _ text: String?, _ option: String?, _ expected: ReviewError,
                     line: UInt = #line) {
            XCTAssertThrowsError(try store.decide(target, action: action, text: text, scopeOptionId: option, now: sampleTime),
                                 line: line) { XCTAssertEqual($0 as? ReviewError, expected, line: line) }
        }
        let hook = Target(targetType: .draft, id: "d-hook")
        XCTAssertEqual(store.status(of: hook), .desktopOnly(.draft))
        XCTAssertEqual(store.status(of: hook).displayText, "Approve this one on your PC")
        refused(hook, .approve, nil, nil, .desktopOnly(.draft))
        refused(Target(targetType: .draft, id: "d-none"), .approve, nil, nil, .unknownItem)
        refused(Target(targetType: .rule, id: "d-0001"), .turnOff, nil, nil, .unknownItem)
        refused(draft1, .turnOff, nil, nil, .actionDoesNotFit)
        refused(rule7, .approve, nil, nil, .actionDoesNotFit)
        refused(Target(targetType: .rule, id: "r-imported"), .edit, "x", nil, .importedRule)
        refused(draft1, .saveEdit, nil, nil, .invalidText)
        refused(draft1, .reject, "x", nil, .invalidText)
        refused(draft1, .delete, nil, "s1", .invalidScope)
        refused(draft1, .approve, "", nil, .invalidText)
        refused(draft1, .approve, "two\nlines", nil, .invalidText)
        refused(draft1, .approve, String(repeating: "x", count: 501), nil, .invalidText)
        refused(draft1, .approve, nil, "s9", .invalidScope)
        XCTAssertNoThrow(try store.decide(draft1, action: .saveEdit, text: nil, scopeOptionId: "s1", now: sampleTime))
        XCTAssertNoThrow(try store.decide(rule7, action: .edit, text: String(repeating: "x", count: 500), scopeOptionId: nil,
                                          now: sampleTime))
        XCTAssertNoThrow(try store.decide(Target(targetType: .rule, id: "r-imported"), action: .turnOff, text: nil,
                                          scopeOptionId: nil, now: sampleTime))
        XCTAssertEqual(store.outbox.count, 3)
    }

    func testCountsReplaceOnEqualOrHigherStoreVersion() throws {
        var store = try self.store()
        let counts = #"{"type":"counts","id":"\#(sampleID)","sentAt":1,"schema":1,"storeVersion":42,"repeatCorrectionsThisWeek":6,"repeatCorrectionsLastWeek":11,"rulesApproved":9,"violationsThisWeek":2,"draftsToday":3,"draftCap":20,"weeks":[]}"#
        store.apply(try decode(counts))
        XCTAssertEqual(store.counts?.rulesApproved, 9)
        store.apply(try decode(counts.replacingOccurrences(of: #""storeVersion":42"#, with: #""storeVersion":41"#)
            .replacingOccurrences(of: #""rulesApproved":9"#, with: #""rulesApproved":1"#)))
        XCTAssertEqual(store.counts?.rulesApproved, 9)
    }

    func testCacheAndOutboxSurviveAJSONRoundTrip() throws {
        var store = try self.store()
        _ = try store.decide(draft1, action: .approve, text: nil, scopeOptionId: nil, now: sampleTime)
        let cache = try JSONDecoder().decode(ReviewCache.self, from: JSONEncoder().encode(store.cache))
        let outbox = try JSONDecoder().decode([OutboxEntry].self, from: JSONEncoder().encode(store.outbox))
        let restored = ReviewStore(cache: cache, outbox: outbox)
        XCTAssertEqual(restored, store)
        XCTAssertEqual(restored.status(of: draft1), .notSent)
        XCTAssertEqual(restored.seenAt(draft1), 42)
        XCTAssertTrue(String(decoding: try JSONEncoder().encode(store.outbox), as: UTF8.self).contains(#""text":null"#))
    }

    func testDemoModeChangesOnlyItsOwnCopy() throws {
        var store = try ReviewStore.demo()
        XCTAssertTrue(store.isDemo)
        XCTAssertEqual(store.drafts.count, 5)
        let ruleCount = store.rules.count
        let first = Target(targetType: .draft, id: "d-0005")
        _ = try store.decide(first, action: .approve, text: "Use sentence case in every heading.", scopeOptionId: "s3",
                             now: sampleTime)
        XCTAssertTrue(store.outbox.isEmpty, "demo mode never sends a decision")
        XCTAssertNil(store.draft(id: "d-0005"))
        XCTAssertEqual(store.rules.count, ruleCount + 1)
        XCTAssertEqual(store.rules.first?.text, "Use sentence case in every heading.")
        XCTAssertEqual(store.status(of: first), .ready)
        let rule = Target(targetType: .rule, id: "r-0007")
        _ = try store.decide(rule, action: .turnOff, text: nil, scopeOptionId: nil, now: sampleTime)
        XCTAssertEqual(store.rule(id: "r-0007")?.state, .off)
        _ = try store.decide(rule, action: .edit, text: "Write each date as YYYY-MM-DD.", scopeOptionId: nil, now: sampleTime)
        XCTAssertEqual(store.rule(id: "r-0007")?.editedOn, .phone)
        _ = try store.decide(Target(targetType: .draft, id: "d-0004"), action: .saveEdit, text: nil, scopeOptionId: "s3",
                             now: sampleTime)
        XCTAssertEqual(store.draft(id: "d-0004")?.scope.kind, .everyProject)
        _ = try store.decide(rule, action: .delete, text: nil, scopeOptionId: nil, now: sampleTime)
        XCTAssertNil(store.rule(id: "r-0007"))
        XCTAssertThrowsError(try store.decide(Target(targetType: .draft, id: "d-0002"), action: .approve, text: nil,
                                              scopeOptionId: nil, now: sampleTime), "the demo hook draft is desktop only")
        XCTAssertEqual(try ReviewStore.demo().drafts.count, 5, "a new demo store starts from the fixtures again")
    }
}

final class ControlFrameTests: XCTestCase {
    let phone = "Ca37EYNT2s_wAbZTVhGMJw"

    func testBuildsHelloAndReceived() throws {
        let device = try DeviceID(base64url: phone)
        let hello = ControlFrame.helloPhone(device: device, token: Data(count: 32))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(hello.utf8)) as? [String: Any])
        XCTAssertEqual(object["op"] as? String, "hello")
        XCTAssertEqual(object["v"] as? Int, 1)
        XCTAssertEqual(object["role"] as? String, "phone")
        XCTAssertEqual(object["device"] as? String, phone)
        XCTAssertEqual(object["token"] as? String, Base64URL.encode(Data(count: 32)))
        let pairing = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(ControlFrame.helloPairing(
            ticket: PairingTicket(bytes: Data(count: 16))).utf8)) as? [String: Any])
        XCTAssertEqual(pairing["role"] as? String, "pairing")
        XCTAssertEqual(pairing["ticket"] as? String, "AAAAAAAAAAAAAAAAAAAAAA")
        XCTAssertEqual(ControlFrame.received(from: .pc, upTo: 1_794_992_460_000),
                       #"{"from":"AAAAAAAAAAAAAAAAAAAAAA","op":"received","upTo":1794992460000}"#)
        XCTAssertEqual(LastideProtocol.webSocketSubprotocol, "lastide-relay.1")
    }

    func testParsesEveryRelayFrameThePhoneReads() throws {
        let welcome = try ControlFrame.parse(#"{"op":"welcome","v":1,"role":"phone","device":"\#(phone)","features":["mailbox"],"pcOnline":true,"pcLastSeenAt":null,"mailbox":2,"attestChallenge":"x","later":[1]}"#)
        guard case .welcome(let w) = welcome else { return XCTFail("not welcome") }
        XCTAssertEqual(w.device?.base64url, phone)
        XCTAssertEqual(w.pcOnline, true)
        XCTAssertNil(w.pcLastSeenAt)
        XCTAssertEqual(w.mailbox, 2)
        guard case .welcome(let pairingWelcome) = try ControlFrame.parse(#"{"op":"welcome","v":1,"role":"pairing","device":null,"features":["mailbox"],"pcOnline":false,"mailbox":0}"#)
        else { return XCTFail("not welcome") }
        XCTAssertNil(pairingWelcome.device)
        XCTAssertEqual(try ControlFrame.parse(#"{"op":"presence","device":"AAAAAAAAAAAAAAAAAAAAAA","online":false}"#),
                       .presence(device: .pc, online: false))
        XCTAssertEqual(try ControlFrame.parse(#"{"op":"stored","to":"AAAAAAAAAAAAAAAAAAAAAA","seq":5}"#), .stored(to: .pc, seq: 5))
        XCTAssertEqual(try ControlFrame.parse(#"{"op":"dropped","to":"AAAAAAAAAAAAAAAAAAAAAA","seq":5,"reason":"offline"}"#),
                       .dropped(to: .pc, seq: 5, reason: "offline"))
        XCTAssertEqual(try ControlFrame.parse(#"{"op":"ok","rid":"1"}"#), .ok(rid: "1"))
        XCTAssertEqual(try ControlFrame.parse(#"{"op":"refused","rid":"1","code":"unsupported"}"#), .refused(rid: "1", code: "unsupported"))
        XCTAssertEqual(try ControlFrame.parse(#"{"op":"refused","rid":null,"code":"badRequest"}"#), .refused(rid: nil, code: "badRequest"))
        XCTAssertEqual(try ControlFrame.parse("pong"), .pong)
    }

    func testRefusesBadRelayFrames() {
        XCTAssertThrowsError(try ControlFrame.parse("ping!")) { XCTAssertEqual($0 as? ControlFrameError, .notJSON) }
        XCTAssertThrowsError(try ControlFrame.parse(#"{"op":"surprise"}"#)) { XCTAssertEqual($0 as? ControlFrameError, .unknownOp("surprise")) }
        XCTAssertThrowsError(try ControlFrame.parse(#"{"op":"welcome","v":2,"role":"phone","device":null,"features":[],"mailbox":0}"#))
        XCTAssertThrowsError(try ControlFrame.parse(#"{"op":"welcome","v":1,"role":"phone","features":[],"mailbox":0}"#), "device missing")
        XCTAssertThrowsError(try ControlFrame.parse(#"{"op":"welcome","v":1,"role":"phone","device":"\#(phone)","features":["mailbox"],"pcLastSeenAt":null,"mailbox":0}"#)) {
            XCTAssertEqual($0 as? ControlFrameError, .badField("pcOnline"))
        }
        XCTAssertThrowsError(try ControlFrame.parse(#"{"op":"welcome","v":1,"role":"pairing","device":null,"features":["mailbox"],"mailbox":0}"#)) {
            XCTAssertEqual($0 as? ControlFrameError, .badField("pcOnline"))
        }
        XCTAssertThrowsError(try ControlFrame.parse(#"{"op":"stored","to":"AAAAAAAAAAAAAAAAAAAAAB","seq":5}"#))
        XCTAssertThrowsError(try ControlFrame.parse(#"{"op":"stored","to":"AAAAAAAAAAAAAAAAAAAAAA","seq":-1}"#))
        XCTAssertThrowsError(try ControlFrame.parse(#"{"op":"presence","device":"AAAAAAAAAAAAAAAAAAAAAA","online":1}"#))
        XCTAssertThrowsError(try ControlFrame.parse(#"{"op":"refused","code":"badRequest"}"#)) { XCTAssertEqual($0 as? ControlFrameError, .badField("rid")) }
        XCTAssertThrowsError(try ControlFrame.parse(#"{"op":"ok","rid":null}"#)) { XCTAssertEqual($0 as? ControlFrameError, .badField("rid")) }
        XCTAssertThrowsError(try ControlFrame.parse(String(repeating: " ", count: 32_769))) { XCTAssertEqual($0 as? ControlFrameError, .tooLarge) }
    }

    func testCloseCodesAndBackoff() {
        XCTAssertEqual(RelayCloseCode.revoked.displayText(pairing: false), "This PC removed this phone.")
        XCTAssertEqual(RelayCloseCode.unsupportedVersion.displayText(pairing: false), "Update the Lastide app.")
        XCTAssertNil(RelayCloseCode.badFrame.displayText(pairing: false))
        XCTAssertTrue(RelayCloseCode.timeout.reconnects)
        XCTAssertFalse(RelayCloseCode.replaced.reconnects)
        var backoff = ReconnectBackoff()
        XCTAssertEqual((0..<11).map { _ in backoff.take() },
                       [1_000, 2_000, 4_000, 8_000, 16_000, 32_000, 64_000, 128_000, 256_000, 300_000, 300_000])
        backoff.reset()
        XCTAssertEqual(backoff.take(), 1_000)
    }
}

final class DemoFixtureTests: XCTestCase {
    func testFixturesValidateAgainstTheSchema() throws {
        let fixtures = try DemoFixtures.load()
        for name in ["queue", "library", "counts"] {
            let message = try SyncMessage.decode(DemoFixtures.plaintext(name))
            XCTAssertEqual(message.type.rawValue, name)
            XCTAssertNoThrow(try message.validate())
        }
        XCTAssertEqual(fixtures.queue.drafts.count, 5)
        XCTAssertEqual(fixtures.library.rules.count, 5)
        XCTAssertEqual(fixtures.counts.weeks.count, 8)
    }

    func testFixturesFollowTheFieldNotes() throws {
        let fixtures = try DemoFixtures.load()
        for draft in fixtures.queue.drafts {
            XCTAssertTrue(draft.scopeOptions.contains { $0.scope == draft.scope }, "\(draft.id): scope equals an option")
            XCTAssertLessThanOrEqual(draft.evidence.count, draft.evidenceCount, draft.id)
        }
        for rule in fixtures.library.rules {
            XCTAssertTrue(rule.scopeOptions.contains { $0.scope == rule.scope }, "\(rule.id): scope equals an option")
        }
        XCTAssertEqual(fixtures.queue.drafts.map(\.createdAt), fixtures.queue.drafts.map(\.createdAt).sorted(by: >), "newest first")
        XCTAssertEqual(fixtures.counts.weeks.map(\.weekStart), fixtures.counts.weeks.map(\.weekStart).sorted(), "oldest week first")
        let kinds = Set(fixtures.queue.drafts.map(\.draftKind))
        XCTAssertTrue(kinds.isSuperset(of: [.new, .rewrite, .contradiction]), "every filter chip shows a draft")
        XCTAssertTrue(fixtures.queue.drafts.contains { $0.desktopOnly })
    }
}
