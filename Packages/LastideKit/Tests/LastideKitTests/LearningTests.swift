import Crypto
import Foundation
@testable import LastideKit
import XCTest

/// Checks K1 to K3 of the learning evidence design (Table 18) and the phone's half of L16, on schema revision 4.
final class LearningTests: XCTestCase {
    var vector: [String: Any] = [:]
    var pcKey: Curve25519.KeyAgreement.PrivateKey!
    var phoneKey: Curve25519.KeyAgreement.PrivateKey!
    var replyKey: Curve25519.KeyAgreement.PrivateKey!
    var pairingID: PairingID!

    override func setUpWithError() throws {
        vector = try XCTUnwrap(Vectors.object("lastide-learning-v1") as? [String: Any])
        let keys = try XCTUnwrap(vector["keys"] as? [String: Any])
        pcKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: hex(keys["pcPrivateKey"]))
        phoneKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: hex(keys["phonePrivateKey"]))
        replyKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: hex(keys["replyPrivateKey"]))
        pairingID = try PairingID(bytes: hex(try XCTUnwrap(vector["ids"] as? [String: Any])["pairingId"]))
    }

    func entry(_ name: String) throws -> [String: Any] { try XCTUnwrap(vector[name] as? [String: Any]) }
    func plaintext(_ name: String) throws -> String { try XCTUnwrap(entry(name)["plaintext"] as? String) }

    // MARK: K1, the four types

    func testK1TheFourTypesTravelAsTable20Says() {
        let rows: [(MessageType, Direction, EnvelopeFlags)] = [
            (.learningRequest, .phoneToPC, []), (.learningPage, .pcToPhone, []),
            (.learningWordsRequest, .phoneToPC, []), (.learningWords, .pcToPhone, .replyKey),
        ]
        for (type, direction, flags) in rows {
            XCTAssertEqual(type.kind, .message, type.rawValue)
            XCTAssertEqual(type.direction, direction, type.rawValue)
            XCTAssertEqual(type.flags, flags, type.rawValue)
            XCTAssertEqual(type.slot, 0, type.rawValue)
            XCTAssertEqual(type.firstRevision, 4, type.rawValue)
        }
        XCTAssertEqual(LastideProtocol.schemaRevision, 4)
    }

    func testK1TheVectorPlaintextsDecodeAtRevisionFourOnly() throws {
        for name in ["learningRequest", "learningPage", "learningWordsRequest", "learningWords"] {
            let data = Data(try plaintext(name).utf8)
            let message = try SyncMessage.decode(data)
            XCTAssertEqual(try SyncMessage.decode(message.encoded()), message, name)
            XCTAssertThrowsError(try SyncMessage.decode(data, revision: 3), name) { error in
                XCTAssertEqual((error as? MessageDecodingError)?.code, .unknownType)
            }
        }
        guard case .learningPage(let page) = try SyncMessage.decode(Data(try plaintext("learningPage").utf8)),
              case .turn(let turn)? = page.rows.first
        else { return XCTFail("the vector's page holds no turn") }
        XCTAssertEqual(page.subject, .repeatWeek(weekStart: "2026-11-16"))
        XCTAssertEqual(page.value, 1)
        XCTAssertEqual(turn.ref, try XCTUnwrap(vector["learningRef"] as? [String: Any])["ref"] as? String)
        XCTAssertEqual(turn.kindScore, 0.83)
        XCTAssertEqual(turn.group?.joinedBy, .words)
        XCTAssertEqual(turn.violations.first?.covered, 0.86)
        guard case .learningWords(let words) = try SyncMessage.decode(Data(try plaintext("learningWords").utf8)) else {
            return XCTFail("not learning-words")
        }
        XCTAssertEqual(words.state, .words)
    }

    /// The phone opens the page with its own key and the words only with the reply key, as section 10.6 says.
    func testK1ThePageOpensWithThePhoneKeyAndTheWordsOnlyWithTheReplyKey() throws {
        func open(_ name: String, with key: Curve25519.KeyAgreement.PrivateKey) throws -> Data {
            let bytes = try hex(entry(name)["envelope"])
            let header = try EnvelopeHeader(frame: bytes)
            var recipient = try HPKE.Recipient(privateKey: key, ciphersuite: LastideProtocol.ciphersuite,
                                               info: Labels.messageInfo(pairingID), encapsulatedKey: header.enc,
                                               authenticatedBy: pcKey.publicKey)
            return try recipient.open(bytes.dropFirst(76), authenticating: header.bytes)
        }
        XCTAssertEqual(String(decoding: try open("learningPage", with: phoneKey), as: UTF8.self), try plaintext("learningPage"))
        XCTAssertEqual(String(decoding: try open("learningWords", with: replyKey), as: UTF8.self), try plaintext("learningWords"))
        XCTAssertThrowsError(try open("learningWords", with: phoneKey), "the words open only with the reply key")
        let header = try EnvelopeHeader(frame: hex(entry("learningWords")["envelope"]))
        XCTAssertEqual(header.flags, .replyKey)
        XCTAssertEqual(header.slot, 0)
    }

    func testK1BadLearningMessagesAreRefused() throws {
        let page = try plaintext("learningPage"), words = try plaintext("learningWords")
        let request = try plaintext("learningRequest"), wordsRequest = try plaintext("learningWordsRequest")
        let turn = #""rowType":"turn","ref":"t-XRqTERYe5h9JUL3fzhiCpg""#
        let bad: [String: String] = [
            "ok page without a list hash": page.replacingOccurrences(of: #""listHash":"-SZtyharSXT6tsHqlP-iHg""#, with: #""listHash":null"#),
            "changed page with rows": page.replacingOccurrences(of: #""state":"ok""#, with: #""state":"changed""#),
            "unknown page state": page.replacingOccurrences(of: #""state":"ok""#, with: #""state":"maybe""#),
            "turn reference with a bad end": page.replacingOccurrences(of: "t-XRqTERYe5h9JUL3fzhiCpg", with: "t-XRqTERYe5h9JUL3fzhiCph"),
            "turn reference without t-": page.replacingOccurrences(of: "t-XRqTERYe5h9JUL3fzhiCpg", with: "XRqTERYe5h9JUL3fzhiCpg"),
            "score above 1": page.replacingOccurrences(of: #""kindScore":0.83"#, with: #""kindScore":1.5"#),
            "score as a boolean": page.replacingOccurrences(of: #""kindScore":0.83"#, with: #""kindScore":true"#),
            "negative contradicts": page.replacingOccurrences(of: #""contradicts":0.03"#, with: #""contradicts":-0.1"#),
            "comment without its label": page.replacingOccurrences(of: #""agent":"claudeCode","commentLabel":null,"#, with: #""agent":null,"#),
            "comment with a typed signal": page.replacingOccurrences(of: #""agent":"claudeCode""#, with: #""agent":null"#),
            "comment label of the wrong shape": page.replacingOccurrences(of: #""commentLabel":null"#, with: #""commentLabel":"7""#),
            "unknown row type": page.replacingOccurrences(of: turn, with: #""rowType":"note","ref":"t-XRqTERYe5h9JUL3fzhiCpg""#),
            "unknown group state": page.replacingOccurrences(of: #""state":"approved""#, with: #""state":"maybe""#),
            "rule text with a line break": page.replacingOccurrences(of: "Use sentence case in headings.", with: #"Use sentence\ncase."#),
            "rule text over 500": page.replacingOccurrences(of: "Use sentence case in headings.", with: String(repeating: "r", count: 501)),
            "missing counted": page.replacingOccurrences(of: #""counted":true,"#, with: ""),
            "missing leftOut": page.replacingOccurrences(of: #""leftOut":{"untraced":0,"older":0,"afterThisWeek":0},"#, with: ""),
            "a turn as the head": page.replacingOccurrences(of: #""head":null"#, with: #""head":{\#(turn)}"#),
            "subject kind unknown": request.replacingOccurrences(of: #""kind":"repeatWeek""#, with: #""kind":"everything""#),
            "subject without its week": request.replacingOccurrences(of: #","weekStart":"2026-11-16""#, with: ""),
            "subject week not a date": request.replacingOccurrences(of: "2026-11-16", with: "2026-11-6"),
            "negative from": request.replacingOccurrences(of: #""from":0"#, with: #""from":-1"#),
            "list hash of 15 bytes": request.replacingOccurrences(of: #""listHash":null"#, with: #""listHash":"AAAAAAAAAAAAAAAAAAAA""#),
            "words request without a reply key": wordsRequest.replacingOccurrences(of: #","replyKey":"jTF4gvNFdipu9KrxzbfJNSAs-7-8EsK_7-tlmGPVImw""#, with: ""),
            "words state without words": words.replacingOccurrences(of: #""words":"Please write headings in sentence case.""#, with: #""words":null"#),
            "empty words": words.replacingOccurrences(of: #""words":"Please write headings in sentence case.""#, with: #""words":"""#),
            "words over 300": words.replacingOccurrences(of: "Please write headings in sentence case.", with: String(repeating: "w", count: 301)),
            "limited without nextAt": words.replacingOccurrences(of: #""state":"words","words":"Please write headings in sentence case.""#, with: #""state":"limited","words":null"#),
            "removed with words": words.replacingOccurrences(of: #""state":"words""#, with: #""state":"removed""#),
        ]
        for (name, json) in bad {
            XCTAssertFalse([page, words, request, wordsRequest].contains(json), "\(name): the change did not apply")
            XCTAssertThrowsError(try decode(json), name) { error in
                XCTAssertEqual((error as? MessageDecodingError)?.code, .badMessage, name)
            }
        }
        var tooMany = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(page.utf8)) as? [String: Any])
        let row = try XCTUnwrap((tooMany["rows"] as? [Any])?.first)
        tooMany["rows"] = Array(repeating: row, count: 51)
        XCTAssertThrowsError(try SyncMessage.decode(JSONSerialization.data(withJSONObject: tooMany)), "51 rows")
        var violations = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(page.utf8)) as? [String: Any])
        var turnObject = try XCTUnwrap((violations["rows"] as? [[String: Any]])?.first)
        let violation = try XCTUnwrap((turnObject["violations"] as? [Any])?.first)
        turnObject["violations"] = Array(repeating: violation, count: 9)
        violations["rows"] = [turnObject]
        XCTAssertThrowsError(try SyncMessage.decode(JSONSerialization.data(withJSONObject: violations)), "9 violations")
        turnObject["violations"] = Array(repeating: violation, count: 8)
        violations["rows"] = [turnObject]
        XCTAssertNoThrow(try SyncMessage.decode(JSONSerialization.data(withJSONObject: violations)), "8 violations")
    }

    func testK1AGoneLimitedOrBlockedPageAndTheOtherWordsStatesPass() throws {
        let page = try plaintext("learningPage")
        let empty = #""from":0,"next":null,"listHash":null,"thresholds":{"kind":0.4,"coverage":0.7,"groupReady":0.5,"groupWait":0.3},"head":null,"rows":[]}"#
        let start = try XCTUnwrap(page.range(of: #""from":0"#)).lowerBound
        for state in ["changed", "gone", "limited", "blocked"] {
            let json = String(page[..<start]).replacingOccurrences(of: #""state":"ok""#, with: #""state":"\#(state)""#)
                .replacingOccurrences(of: #""value":1,"total":1"#, with: #""value":0,"total":0"#) + empty
            XCTAssertNoThrow(try decode(json), state)
        }
        let words = try plaintext("learningWords")
        let removed = words.replacingOccurrences(of: #""state":"words","words":"Please write headings in sentence case.""#,
                                                 with: #""state":"removed","words":null"#)
        XCTAssertNoThrow(try decode(removed))
        let limited = words.replacingOccurrences(of: #""state":"words","words":"Please write headings in sentence case.","nextAt":null"#,
                                                 with: #""state":"limited","words":null,"nextAt":1794996000000"#)
        guard case .learningWords(let answer) = try decode(limited) else { return XCTFail("not learning-words") }
        XCTAssertEqual(answer.nextAt, 1_794_996_000_000)
    }

    // MARK: K1, the list restarts on `changed`

    func page(_ request: LearningRequest, state: LearningPageState = .ok, value: Int = 3, rows: Int = 2, next: Int? = nil,
              hash: String = "-SZtyharSXT6tsHqlP-iHg", older: Int = 0) throws -> LearningPage {
        guard case .learningPage(let template) = try SyncMessage.decode(Data(try plaintext("learningPage").utf8)) else {
            throw ValidationError(path: "", rule: "no page")
        }
        let ok = state == .ok
        return LearningPage(id: makeMessageID(), sentAt: sampleTime, requestId: request.id, subject: request.subject, state: state,
                            storeVersion: 44, asOf: sampleTime, value: ok ? value : 0, total: ok ? value - older : 0,
                            leftOut: LearningLeftOut(untraced: 0, older: ok ? older : 0, afterThisWeek: 0), from: request.from,
                            next: ok ? next : nil, listHash: ok ? hash : nil, thresholds: template.thresholds, head: nil,
                            rows: ok ? Array(repeating: template.rows[0], count: rows) : [])
    }

    func testK1AListThatChangesAsksForItsFirstPageAgainAndStopsAfterThreeTimes() throws {
        let subject = LearningSubject.repeatWeek(weekStart: "2026-11-16")
        var (list, first) = LearningList.ask(subject, now: sampleTime)
        XCTAssertEqual(first.from, 0)
        XCTAssertNil(first.listHash)
        XCTAssertEqual(list.phase, .asking)
        // A page that answers another request changes nothing.
        let stranger = LearningRequest(id: makeMessageID(), sentAt: sampleTime, subject: subject, from: 0, listHash: nil)
        XCTAssertEqual(list.apply(try page(stranger), now: sampleTime), .ignored)
        XCTAssertEqual(list.apply(try page(first, value: 3, rows: 2, next: 2), now: sampleTime), .shown)
        XCTAssertEqual(list.rows.count, 2)
        let second = try XCTUnwrap(list.nextRequest(now: sampleTime))
        XCTAssertEqual(second.from, 2)
        XCTAssertEqual(second.listHash, "-SZtyharSXT6tsHqlP-iHg")
        XCTAssertNil(list.nextRequest(now: sampleTime), "one page request at a time")
        var current = second
        for attempt in 1...LearningList.restartLimit {
            guard case .askAgain(let again) = list.apply(try page(current, state: .changed), now: sampleTime) else {
                return XCTFail("changed did not ask again on attempt \(attempt)")
            }
            XCTAssertEqual(again.from, 0)
            XCTAssertNil(again.listHash)
            XCTAssertTrue(list.rows.isEmpty, "no row shows twice")
            XCTAssertTrue(list.restarted)
            current = again
        }
        XCTAssertEqual(list.apply(try page(current, state: .changed), now: sampleTime), .stopped)
        XCTAssertEqual(list.phase, .changedTooOften)
        // A later page whose hash differs from the first page's starts over too.
        var (other, otherFirst) = LearningList.ask(subject, now: sampleTime)
        _ = other.apply(try page(otherFirst, value: 3, rows: 2, next: 2), now: sampleTime)
        let otherSecond = try XCTUnwrap(other.nextRequest(now: sampleTime))
        guard case .askAgain(let again) = other.apply(try page(otherSecond, rows: 1, hash: "AAAAAAAAAAAAAAAAAAAAAA"),
                                                      now: sampleTime) else {
            return XCTFail("a page of another list did not start over")
        }
        XCTAssertEqual(again.from, 0)
        XCTAssertNotEqual(again.id, otherFirst.id)
    }

    func testK1PagesAppendAndTheOtherStatesStopTheList() throws {
        let subject = LearningSubject.rulesOn
        var (list, first) = LearningList.ask(subject, now: sampleTime)
        _ = list.apply(try page(first, value: 3, rows: 2, next: 2), now: sampleTime)
        let second = try XCTUnwrap(list.nextRequest(now: sampleTime))
        XCTAssertEqual(list.apply(try page(second, value: 3, rows: 1), now: sampleTime), .shown)
        XCTAssertEqual(list.rows.count, 3)
        XCTAssertNil(list.next)
        XCTAssertNil(list.mismatch(expected: 3))
        for (state, phase) in [(LearningPageState.gone, LearningListPhase.gone), (.limited, .limited), (.blocked, .blocked)] {
            var (stopped, request) = LearningList.ask(subject, now: sampleTime)
            XCTAssertEqual(stopped.apply(try page(request, state: state), now: sampleTime), .stopped)
            XCTAssertEqual(stopped.phase, phase)
            XCTAssertTrue(stopped.rows.isEmpty)
            request = stopped.askAgain(now: sampleTime)
            XCTAssertEqual(stopped.phase, .asking)
        }
        var (late, _) = LearningList.ask(subject, now: sampleTime)
        XCTAssertFalse(late.checkTimeout(now: sampleTime + 9_999))
        XCTAssertTrue(late.checkTimeout(now: sampleTime + 10_000))
        XCTAssertEqual(late.phase, .noAnswer)
    }

    // MARK: K2, reply keys by request

    func testK2AnEvidenceAnswerLeavesTheReplyKeyOfAnOpenLearningRow() throws {
        var f = PairedFixture()
        let words = f.session.makeLearningWordsRequest(ref: "t-XRqTERYe5h9JUL3fzhiCpg", now: sampleTime)
        let evidence = f.session.makeEvidenceRequest(draftID: "d-0001", storeVersion: 42, now: sampleTime)
        XCTAssertEqual(f.session.waitingReplyKeyCount, 2)
        func key(_ text: String) throws -> Curve25519.KeyAgreement.PublicKey {
            try Curve25519.KeyAgreement.PublicKey(rawRepresentation: Base64URL.decode(text, byteCount: 32))
        }
        let evidenceJSON = #"{"type":"evidence","id":"\#(makeMessageID())","sentAt":\#(sampleTime),"requestId":"\#(evidence.id)","draftId":"d-0001","changedAtStoreVersion":41,"rationale":null,"items":[]}"#
        guard case .message(.evidence, _) = f.session.receive(try f.fromPC(evidenceJSON, flags: .replyKey,
                                                                            recipientKey: try key(evidence.replyKey)),
                                                              now: sampleTime) else {
            return XCTFail("the evidence did not open")
        }
        XCTAssertFalse(f.session.holdsReplyKey(for: evidence.id), "a key opens one answer")
        XCTAssertTrue(f.session.holdsReplyKey(for: words.id), "the open row's key stays")
        let wordsJSON = #"{"type":"learning-words","id":"\#(makeMessageID())","sentAt":\#(sampleTime),"requestId":"\#(words.id)","ref":"t-XRqTERYe5h9JUL3fzhiCpg","state":"words","words":"Synthetic words.","nextAt":null}"#
        guard case .message(.learningWords(let answer), _) = f.session.receive(
            try f.fromPC(wordsJSON, flags: .replyKey, recipientKey: try key(words.replyKey)), now: sampleTime) else {
            return XCTFail("the words did not open after the evidence")
        }
        XCTAssertEqual(answer.words, "Synthetic words.")
        XCTAssertEqual(f.session.waitingReplyKeyCount, 0)
    }

    func testK2AnAnswerThatNamesAnotherRequestIsUnusableAndOneKeyDropsAlone() throws {
        var f = PairedFixture()
        let first = f.session.makeLearningWordsRequest(ref: "t-XRqTERYe5h9JUL3fzhiCpg", now: sampleTime)
        let second = f.session.makeLearningWordsRequest(ref: "t-txdOVGLk8BxbhsCgnl7J1w", now: sampleTime)
        let key = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: Base64URL.decode(first.replyKey, byteCount: 32))
        let other = #"{"type":"learning-words","id":"\#(makeMessageID())","sentAt":\#(sampleTime),"requestId":"\#(second.id)","ref":"t-txdOVGLk8BxbhsCgnl7J1w","state":"gone","words":null,"nextAt":null}"#
        guard case .unusable(let reply, _) = f.session.receive(try f.fromPC(other, flags: .replyKey, recipientKey: key),
                                                              now: sampleTime) else {
            return XCTFail("an answer under another request's key was used")
        }
        XCTAssertEqual(reply?.code, .badMessage)
        f.session.dropReplyKey(requestID: second.id)
        XCTAssertFalse(f.session.holdsReplyKey(for: second.id))
        XCTAssertEqual(f.session.waitingReplyKeyCount, 0, "the first key opened its envelope, so it is gone too")
        let request = f.session.makeLearningWordsRequest(ref: "t-XRqTERYe5h9JUL3fzhiCpg", now: sampleTime)
        let sealed = try f.session.seal(.learningWordsRequest(request), now: sampleTime)
        let (header, plaintext) = try f.pc.openMessage(sealed.bytes, from: f.phoneKey.publicKey)
        XCTAssertEqual(header.flags, [])
        XCTAssertEqual(header.slot, 0)
        XCTAssertEqual(try SyncMessage.decode(plaintext), .learningWordsRequest(request))
    }

    // MARK: K3, the sum check

    func testK3AListWhoseNumberDiffersFromTheScreenShowsTheMismatchLine() throws {
        let subject = LearningSubject.repeatWeek(weekStart: "2026-11-16")
        var (list, request) = LearningList.ask(subject, now: sampleTime)
        _ = list.apply(try page(request, value: 6, rows: 6), now: sampleTime)
        XCTAssertNil(list.mismatch(expected: 6))
        let difference = try XCTUnwrap(list.mismatch(expected: 7))
        XCTAssertEqual(LearningText.mismatch(counted: difference.counted, listed: difference.listed), "Your PC counted 7 and listed 6.")
        // Rows that do not add up to the number show the line once the last page arrived.
        (list, request) = LearningList.ask(subject, now: sampleTime)
        let short = LearningPage(id: makeMessageID(), sentAt: sampleTime, requestId: request.id, subject: subject, state: .ok,
                                 storeVersion: 44, asOf: sampleTime, value: 5, total: 5,
                                 leftOut: LearningLeftOut(untraced: 0, older: 0, afterThisWeek: 0), from: 0, next: nil,
                                 listHash: "-SZtyharSXT6tsHqlP-iHg", thresholds: try page(request).thresholds, head: nil,
                                 rows: try page(request, rows: 4).rows)
        _ = list.apply(short, now: sampleTime)
        let rows = try XCTUnwrap(list.mismatch(expected: 5))
        XCTAssertEqual(LearningText.mismatch(counted: rows.counted, listed: rows.listed), "Your PC counted 5 and listed 4.")
        // Older items count toward the number without a row.
        (list, request) = LearningList.ask(.draft(id: "d-0001"), now: sampleTime)
        _ = list.apply(try page(request, value: 5, rows: 3, older: 2), now: sampleTime)
        XCTAssertNil(list.mismatch(expected: 5))
        XCTAssertEqual(LearningText.older(2, subject: .draft(id: "d-0001")), "2 more corrections of this draft were not kept.")
    }

    // MARK: The revision 4 fields of counts

    func testRevisionFourCountsFieldsDecodeAndAnOlderMessageStaysAsItCame() throws {
        let four = #"{"type":"counts","id":"\#(sampleID)","sentAt":\#(sampleTime),"schema":4,"storeVersion":42,"repeatCorrectionsThisWeek":6,"repeatCorrectionsLastWeek":11,"rulesApproved":4,"violationsThisWeek":null,"draftsToday":2,"draftCap":null,"draftingRunsToday":4,"draftingRunCap":20,"importRulesWaiting":12,"weeks":[{"weekStart":"2026-11-09","repeatCorrections":11,"violations":2,"repeatState":"measured","violationState":"notMeasured","waiting":null,"untraced":1},{"weekStart":"2026-11-16","repeatCorrections":6,"violations":0,"repeatState":"partial","violationState":"notMeasured","waiting":3,"untraced":0}],"rulesApprovedThisWeek":1,"repeatCorrectionsLastWeekByNow":4,"violationsLastWeekByNow":null,"draftingRunsFinishedToday":2,"measuredFrom":null,"today":"2026-11-18"}"#
        guard case .counts(let counts) = try decode(four) else { return XCTFail("not counts") }
        XCTAssertTrue(counts.hasRevisionFour)
        XCTAssertEqual(counts.rulesApprovedThisWeek, 1)
        XCTAssertEqual(counts.repeatCorrectionsLastWeekByNow, .some(4))
        XCTAssertEqual(counts.violationsLastWeekByNow, .some(nil))
        XCTAssertEqual(counts.measuredFrom, .some(nil))
        XCTAssertEqual(counts.weeks[0].waiting, .some(nil))
        XCTAssertEqual(counts.weeks[1].waiting, .some(3))
        XCTAssertEqual(counts.weeks[0].violationState, .notMeasured)
        XCTAssertEqual(counts.number(for: .rulesApprovedWeek(weekStart: "2026-11-16")), 1)
        XCTAssertNil(counts.number(for: .rulesApprovedWeek(weekStart: "2026-11-09")))
        XCTAssertEqual(counts.number(for: .draftsToday(day: "2026-11-18")), 2)
        XCTAssertNil(counts.number(for: .draftsToday(day: "2026-11-17")))
        let encoded = String(decoding: try SyncMessage.counts(counts).encoded(), as: UTF8.self)
        XCTAssertTrue(encoded.contains(#""measuredFrom":null"#), "a null field stays null")
        XCTAssertTrue(encoded.contains(#""waiting":null"#))
        let bad = four.replacingOccurrences(of: #""today":"2026-11-18""#, with: #""today":"18 Nov""#)
        XCTAssertThrowsError(try decode(bad))
        XCTAssertThrowsError(try decode(four.replacingOccurrences(of: #""repeatState":"measured""#, with: #""repeatState":"some""#)))

        let three = #"{"type":"counts","id":"\#(sampleID)","sentAt":\#(sampleTime),"schema":3,"storeVersion":42,"repeatCorrectionsThisWeek":6,"repeatCorrectionsLastWeek":11,"rulesApproved":9,"violationsThisWeek":2,"draftsToday":3,"draftCap":null,"weeks":[{"weekStart":"2026-11-16","repeatCorrections":6,"violations":2}]}"#
        guard case .counts(let old) = try decode(three) else { return XCTFail("not counts") }
        XCTAssertFalse(old.hasRevisionFour)
        XCTAssertNil(old.repeatCorrectionsLastWeekByNow)
        let oldText = String(decoding: try SyncMessage.counts(old).encoded(), as: UTF8.self)
        for field in ["measuredFrom", "today", "repeatState", "waiting", "rulesApprovedThisWeek", "ByNow"] {
            XCTAssertFalse(oldText.contains(field), "a revision 3 message gains no \(field)")
        }
    }

    // MARK: L16, the phone's half

    /// Twelve weeks from 2026-09-07, oldest first. The last one holds now. The same cases as the desktop's test.
    func weeks(_ values: [Any?]) -> [CaptionWeek] {
        precondition(values.count == 12)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let start = calendar.date(from: DateComponents(year: 2026, month: 9, day: 7))!
        return values.enumerated().map { index, value in
            let date = calendar.date(byAdding: .day, value: 7 * index, to: start)!
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            let weekStart = String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
            switch value {
            case nil: return CaptionWeek(weekStart: weekStart, value: nil, state: .notMeasured)
            case let number as Int: return CaptionWeek(weekStart: weekStart, value: number, state: index == 11 ? .partial : .measured)
            case let (number, state) as (Int, LearningSpan): return CaptionWeek(weekStart: weekStart, value: number, state: state)
            default: preconditionFailure("a week is nil, a number or a number with its state")
            }
        }
    }

    let bars = "A shorter bar means fewer repeats. A week with fewer messages has a shorter bar too."

    func testL16TheCaptionComparesCompleteMeasuredWeeksOnly() {
        let n: Any? = nil
        XCTAssertEqual(LearningText.caption(.repeats, weeks: weeks([n, n, n, n, n, n, n, n, 3, 3, 3, 1]), thisWeekSoFar: 1, lastWeekByNow: 2),
                       "Repeat corrections went from 3 in the week of 2026-11-02 to 3 in the week of 2026-11-16: no change. Of the last 2 week-to-week changes, 0 went down, 0 went up and 2 stayed the same. This week so far: 1. By this time last week: 2. \(bars)")
        XCTAssertEqual(LearningText.caption(.repeats, weeks: weeks([n, n, n, n, n, n, n, n, n, n, 4, 2]), thisWeekSoFar: 2, lastWeekByNow: 3),
                       "A change shows after two complete weeks. This week so far: 2. By this time last week: 3. \(bars)")
        XCTAssertEqual(LearningText.caption(.repeats, weeks: weeks([n, n, n, n, n, n, n, n, n, 2, 5, 0]), thisWeekSoFar: 0, lastWeekByNow: 1),
                       "Repeat corrections went from 2 in the week of 2026-11-09 to 5 in the week of 2026-11-16: 3 more. This week so far: 0. By this time last week: 1. \(bars)")
        XCTAssertEqual(LearningText.caption(.violations, weeks: weeks([n, n, n, n, n, n, n, 6, 4, 5, 2, 1]), thisWeekSoFar: 1, lastWeekByNow: nil),
                       "Violations went from 6 in the week of 2026-10-26 to 2 in the week of 2026-11-16: 4 fewer. Of the last 3 week-to-week changes, 2 went down, 1 went up and 0 stayed the same. This week so far: 1. A shorter bar means fewer violations. A week with fewer messages has a shorter bar too.")
        XCTAssertEqual(LearningText.caption(.repeats, weeks: weeks([n, n, n, n, n, n, n, n, 4, n, 2, 3]), thisWeekSoFar: 3, lastWeekByNow: 1),
                       "Repeat corrections went from 4 in the week of 2026-11-02 to 2 in the week of 2026-11-16: 2 fewer. This week so far: 3. By this time last week: 1. \(bars)")
        XCTAssertEqual(LearningText.caption(.repeats, weeks: weeks([n, n, n, n, n, n, n, n, (9, LearningSpan.partial), 5, 4, 0]), thisWeekSoFar: 0, lastWeekByNow: 3),
                       "Repeat corrections went from 5 in the week of 2026-11-09 to 4 in the week of 2026-11-16: 1 fewer. This week so far: 0. By this time last week: 3. \(bars)")
        XCTAssertEqual(LearningText.caption(.repeats, weeks: weeks([n, n, n, n, n, n, n, 2, n, 3, 1, 0]), thisWeekSoFar: nil, lastWeekByNow: nil),
                       "Repeat corrections went from 2 in the week of 2026-10-26 to 1 in the week of 2026-11-16: 1 fewer. The one week-to-week change went down. \(bars)")
    }

    func testTheScoreSentencesAndTheTextsOfTable5() {
        XCTAssertEqual(LearningText.kindScore(0.83, threshold: 0.4), "The model's score: 0.83. A message counts from 0.40.")
        XCTAssertEqual(LearningText.label(.drafts), "Drafts written by drafting runs")
        XCTAssertEqual(LearningText.line(.drafts, pcName: "WORKSTATION-A"), "Since midnight on WORKSTATION-A")
        XCTAssertEqual(LearningText.line(.runs, pcName: "WORKSTATION-A", finished: 2, notFinished: 2), "2 finished, 2 did not")
        XCTAssertEqual(LearningText.repeatsLastWeek(byNow: 7, all: 11), "By this time last week: 7. All of last week: 11.")
        XCTAssertEqual(LearningText.cost(micros: 98_000).prefix(8), "$0.0980,")
        XCTAssertEqual(LearningText.number(52_000), "52,000")
        XCTAssertEqual(LearningText.number(999), "999")
        XCTAssertEqual(LearningText.definition(.violations, thresholds: nil, cap: 20).contains("at 0.70 or more"), true)
    }

    // MARK: The demo lists

    func testTheDemoListsEqualTheDemoNumbers() throws {
        let fixtures = try DemoFixtures.load()
        let demo = try DemoLearning.load()
        let counts = fixtures.counts
        XCTAssertTrue(counts.hasRevisionFour, "the demo counts carry the fields of revision 4")
        XCTAssertEqual(demo.asOf, counts.sentAt)
        var subjects: [LearningSubject] = [.rulesOn]
        if let today = counts.today { subjects += [.draftsToday(day: today), .runsToday(day: today)] }
        for week in counts.weeks {
            subjects += [.repeatWeek(weekStart: week.weekStart), .violationWeek(weekStart: week.weekStart)]
        }
        subjects.append(.rulesApprovedWeek(weekStart: try XCTUnwrap(counts.weeks.last).weekStart))
        for subject in subjects {
            let list = try XCTUnwrap(demo.lists[subject], "\(subject)")
            XCTAssertEqual(list.value, counts.number(for: subject), "\(subject)")
        }
        let weekStart = try XCTUnwrap(counts.weeks.last).weekStart
        XCTAssertEqual(demo.lists[.repeatWeek(weekStart: weekStart)]?.value, counts.repeatCorrectionsThisWeek)
        XCTAssertEqual(demo.lists[.violationWeek(weekStart: weekStart)]?.value, counts.violationsThisWeek)
        XCTAssertEqual(demo.lists[.runsToday(day: try XCTUnwrap(counts.today))]?.rows.filter {
            if case .run(let run) = $0 { return run.state == .finished } else { return false }
        }.count, counts.draftingRunsFinishedToday)
        for rule in fixtures.library.rules {
            XCTAssertEqual(demo.lists[.rule(id: rule.id)]?.value, rule.violationsSinceApproval, rule.id)
        }
        // Every link a row or a head offers opens a list of the demo.
        for list in demo.lists.values {
            for row in list.rows {
                switch row {
                case .turn(let turn):
                    if let group = turn.group { XCTAssertNotNil(demo.lists[.group(id: group.id)], group.id) }
                    for violation in turn.violations { XCTAssertNotNil(demo.lists[.rule(id: violation.ruleId)], violation.ruleId) }
                case .rule(let rule):
                    XCTAssertNotNil(demo.lists[.rule(id: rule.id)], rule.id)
                case .draft(let draft):
                    XCTAssertNotNil(demo.lists[.draft(id: draft.id)], draft.id)
                    if let runId = draft.runId { XCTAssertNotNil(demo.lists[.run(id: runId)], runId) }
                    if let groupId = draft.groupId { XCTAssertNotNil(demo.lists[.group(id: groupId)], groupId) }
                case .run(let run):
                    XCTAssertNotNil(demo.lists[.run(id: run.id)], run.id)
                }
            }
        }
        // A list longer than one page pages by 50 rows, and a later page with another hash answers changed.
        let long = try XCTUnwrap(demo.lists.values.first { $0.total > 0 })
        let first = demo.page(LearningRequest(id: makeMessageID(), sentAt: 0, subject: long.subject, from: 0, listHash: nil))
        XCTAssertEqual(first.state, .ok)
        XCTAssertEqual(first.rows.count, min(50, long.total))
        let changed = demo.page(LearningRequest(id: makeMessageID(), sentAt: 0, subject: long.subject, from: 1,
                                                listHash: "AAAAAAAAAAAAAAAAAAAAAA"))
        XCTAssertEqual(changed.state, .changed)
        let gone = demo.page(LearningRequest(id: makeMessageID(), sentAt: 0, subject: .rule(id: "r-none"), from: 0, listHash: nil))
        XCTAssertEqual(gone.state, .gone)
    }
}
