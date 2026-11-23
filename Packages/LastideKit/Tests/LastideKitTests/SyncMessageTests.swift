import Foundation
@testable import LastideKit
import XCTest

/// The valid and invalid examples of the spec author's schema check, and the constraints Swift must check by hand.
final class SyncMessageTests: XCTestCase {
    let id = sampleID, t = sampleTime, key = "Lyp3cyFr999gCNiZushXTobERqaRY2p-hE84j8GKhEA"
    let scope = #"{"scope":"everyProject","kindOfWork":null,"projectNames":[]}"#

    func vectorPlaintext(_ name: String) throws -> String {
        let vector = try XCTUnwrap(Vectors.object("lastide-v1") as? [String: Any])
        return try XCTUnwrap((vector[name] as? [String: Any])?["plaintext"] as? String)
    }

    var good: [String: String] {
        let draft = draftJSON()
        return [
            "pair-refuse": #"{"type":"pair-refuse","id":"\#(id)","sentAt":\#(t),"pairingId":"\#(id)","phoneId":"\#(id)","reason":"wrongCode"}"#,
            "library": libraryJSON(storeVersion: 42),
            "counts": #"{"type":"counts","id":"\#(id)","sentAt":\#(t),"schema":1,"storeVersion":42,"repeatCorrectionsThisWeek":6,"repeatCorrectionsLastWeek":11,"rulesApproved":9,"violationsThisWeek":2,"draftsToday":3,"draftCap":20,"weeks":[{"weekStart":"2026-11-16","repeatCorrections":6,"violations":2}]}"#,
            "evidence": #"{"type":"evidence","id":"\#(id)","sentAt":\#(t),"requestId":"\#(id)","draftId":"d-0001","changedAtStoreVersion":41,"rationale":"Three corrections ask for sentence case.","items":[{"evidenceId":"1","state":"words","words":"Headings again, only the first word gets a capital."},{"evidenceId":"2","state":"removed","words":null}]}"#,
            "acknowledgement applied": acknowledgementJSON(decisionId: id, result: "applied", reason: nil, storeVersion: 43),
            "acknowledgement refused": acknowledgementJSON(decisionId: id, result: "refused", reason: "staleVersion", storeVersion: 43,
                                                           current: #"{"targetType":"draft","draft":\#(draft)}"#),
            "acknowledgement rule": acknowledgementJSON(decisionId: id, result: "applied", reason: nil, storeVersion: 43,
                                                        current: #"{"targetType":"rule","rule":\#(ruleJSON())}"#),
            "acknowledgement expired": acknowledgementJSON(decisionId: id, result: "refused", reason: "expired", storeVersion: 43),
            "decision": #"{"type":"decision","id":"\#(id)","sentAt":\#(t),"decisionId":"\#(id)","target":{"targetType":"draft","id":"d-0001"},"storeVersion":42,"action":"approve","text":"Use sentence case in every heading.","scopeOptionId":"s3","decidedAt":\#(t)}"#,
            "sync": #"{"type":"sync","id":"\#(id)","sentAt":\#(t),"schema":1,"have":{"queue":41,"library":null}}"#,
            "evidence-request": #"{"type":"evidence-request","id":"\#(id)","sentAt":\#(t),"draftId":"d-0001","storeVersion":42,"replyKey":"\#(key)"}"#,
            "unpair": #"{"type":"unpair","id":"\#(id)","sentAt":\#(t)}"#,
            "error": #"{"type":"error","id":"\#(id)","sentAt":\#(t),"inReplyTo":null,"code":"badMessage","detail":"flags do not match the type"}"#,
            "notice": #"{"type":"notice","id":"\#(id)","sentAt":\#(t),"storeVersion":42,"queueCount":4,"draft":{"id":"d-0001","changedAtStoreVersion":41,"draftKind":"new","text":"Use sentence case in headings.","scope":\#(scope)}}"#,
            "notice without draft": #"{"type":"notice","id":"\#(id)","sentAt":\#(t),"storeVersion":42,"queueCount":4,"draft":null}"#,
            "kindOfWork scope": queueJSON(storeVersion: 1, drafts: [draftJSON().replacingOccurrences(of: scope, with: #"{"scope":"kindOfWork","kindOfWork":"code review","projectNames":["a"]}"#)]),
            "unknown fields are ignored": #"{"type":"unpair","id":"\#(id)","sentAt":\#(t),"later":{"x":1}}"#,
        ]
    }

    func testVectorPlaintextsAndGoodExamplesPass() throws {
        let vector = try XCTUnwrap(Vectors.object("lastide-v1") as? [String: Any])
        for name in ["pairRequest", "pairReceived", "pairAccept", "message"] {
            let plaintext = try XCTUnwrap((vector[name] as? [String: Any])?["plaintext"] as? String)
            XCTAssertNoThrow(try decode(plaintext), name)
        }
        for (name, json) in good {
            XCTAssertNoThrow(try decode(json), name)
        }
    }

    func testEncodingIsByteForByteRepeatable() throws {
        for (name, json) in good {
            let message = try SyncMessage.decode(Data(json.utf8))
            let first = try message.encoded()
            for _ in 0..<20 { XCTAssertEqual(try message.encoded(), first, name) }
        }
    }

    func testBadExamplesAreRefused() throws {
        let queue = try vectorPlaintext("message")
        let decision = good["decision"]!
        let notice = good["notice"]!
        let evidence = good["evidence"]!
        let applied = good["acknowledgement applied"]!
        let refused = good["acknowledgement refused"]!
        let pairAccept = try vectorPlaintext("pairAccept")
        let pairRequest = try vectorPlaintext("pairRequest")
        let bad: [String: (String, ErrorCode)] = [
            "unknown type": (#"{"type":"hello","id":"\#(id)","sentAt":\#(t)}"#, .unknownType),
            "padded id": (#"{"type":"unpair","id":"\#(id)==","sentAt":\#(t)}"#, .badMessage),
            "non-canonical 16-byte id": (#"{"type":"unpair","id":"GPEkxfZwlv5u32ui7BBUtB","sentAt":\#(t)}"#, .badMessage),
            "decision text with a line break": (decision.replacingOccurrences(of: "every heading.", with: #"every\nheading."#), .badMessage),
            "decision text with a carriage return": (decision.replacingOccurrences(of: "every heading.", with: #"every\rheading."#), .badMessage),
            "decision with the old target shape": (decision.replacingOccurrences(of: #"{"targetType":"draft","id":"d-0001"}"#, with: #"{"kind":"draft","id":"d-0001","version":1}"#), .badMessage),
            "thisProject without a project": (notice.replacingOccurrences(of: scope, with: #"{"scope":"thisProject","kindOfWork":null,"projectNames":[]}"#), .badMessage),
            "applied with a reason": (applied.replacingOccurrences(of: #""reason":null"#, with: #""reason":"gone""#), .badMessage),
            "refused without a reason": (refused.replacingOccurrences(of: #""reason":"staleVersion""#, with: #""reason":null"#), .badMessage),
            "acknowledgement without storeVersion": (applied.replacingOccurrences(of: #""storeVersion":43,"#, with: ""), .badMessage),
            "words state without words": (evidence.replacingOccurrences(of: #""words":"Headings again, only the first word gets a capital.""#, with: #""words":null"#), .badMessage),
            "unknown signal": (queue.replacingOccurrences(of: #""signal":"typedTurn""#, with: #""signal":"telepathy""#), .badMessage),
            "queue without schema": (queue.replacingOccurrences(of: #""schema":1,"#, with: ""), .badMessage),
            "pair-accept without mailbox": (pairAccept.replacingOccurrences(of: #"["mailbox"]"#, with: "[]"), .badMessage),
            "pair-request without model": (pairRequest.replacingOccurrences(of: #""model":"iPhone17,3","#, with: ""), .badMessage),
            "evidence-request without replyKey": (#"{"type":"evidence-request","id":"\#(id)","sentAt":\#(t),"draftId":"d-0001","storeVersion":42}"#, .badMessage),
            "error code tooLarge": (good["error"]!.replacingOccurrences(of: "badMessage", with: "tooLarge"), .badMessage),
            "time past 2^53": (#"{"type":"unpair","id":"\#(id)","sentAt":9007199254740992}"#, .badMessage),
        ]
        for (name, (json, code)) in bad {
            XCTAssertThrowsError(try decode(json), name) { error in
                XCTAssertEqual((error as? MessageDecodingError)?.code, code, name)
            }
        }
    }

    /// Each constraint of Constraints.md that the borrowed examples do not reach.
    func testEveryOtherConstraint() throws {
        let draft = draftJSON()
        let rule = ruleJSON()
        func queue(_ edit: (String) -> String) -> String { queueJSON(storeVersion: 42, drafts: [edit(draft)]) }
        func library(_ edit: (String) -> String) -> String { libraryJSON(storeVersion: 42, rules: [edit(rule)]) }
        let refusals: [String: String] = [
            "draft text empty": queue { $0.replacingOccurrences(of: "Use sentence case in headings.", with: "") },
            "draft text over 4000": queue { $0.replacingOccurrences(of: "Use sentence case in headings.", with: String(repeating: "a", count: 4001)) },
            "item id with a space": queue { $0.replacingOccurrences(of: #""id":"d-0001""#, with: #""id":"d 1""#) },
            "item id over 64": queue { $0.replacingOccurrences(of: #""id":"d-0001""#, with: #""id":"\#(String(repeating: "d", count: 65))""#) },
            "no scope options": queue { $0.replacingOccurrences(of: #"[{"id":"s1","scope":"thisProject","kindOfWork":null,"projectNames":["northwind-reports"]},{"id":"s3","scope":"everyProject","kindOfWork":null,"projectNames":[]}]"#, with: "[]") },
            "scope option id over 16": queue { $0.replacingOccurrences(of: #""id":"s1""#, with: #""id":"s12345678901234567""#) },
            "everyProject with a project": queue { $0.replacingOccurrences(of: #""scope":"everyProject","kindOfWork":null,"projectNames":[]"#, with: #""scope":"everyProject","kindOfWork":null,"projectNames":["a"]"#) },
            "kindOfWork without a kind": queue { $0.replacingOccurrences(of: #""scope":"everyProject","kindOfWork":null,"#, with: #""scope":"kindOfWork","kindOfWork":null,"#) },
            "kindOfWork empty": queue { $0.replacingOccurrences(of: #""scope":"everyProject","kindOfWork":null,"#, with: #""scope":"kindOfWork","kindOfWork":"","#) },
            "duplicate project names": queue { $0.replacingOccurrences(of: #"["northwind-reports"]"#, with: #"["a","a"]"#) },
            "empty project name": queue { $0.replacingOccurrences(of: #"["northwind-reports"]"#, with: #"[""]"#) },
            "project name over 128": queue { $0.replacingOccurrences(of: "northwind-reports", with: String(repeating: "p", count: 129)) },
            "no agents": queue { $0.replacingOccurrences(of: #"["claudeCode","codex"]"#, with: "[]") },
            "duplicate agents": queue { $0.replacingOccurrences(of: #"["claudeCode","codex"]"#, with: #"["codex","codex"]"#) },
            "unknown agent": queue { $0.replacingOccurrences(of: #"["claudeCode","codex"]"#, with: #"["cursor"]"#) },
            "unknown draft kind": queue { $0.replacingOccurrences(of: #""draftKind":"new""#, with: #""draftKind":"old""#) },
            "negative count": queue { $0.replacingOccurrences(of: #""evidenceCount":3"#, with: #""evidenceCount":-1"#) },
            "fractional count": queue { $0.replacingOccurrences(of: #""evidenceCount":3"#, with: #""evidenceCount":3.5"#) },
            "count as a string": queue { $0.replacingOccurrences(of: #""evidenceCount":3"#, with: #""evidenceCount":"3""#) },
            "boolean as a number": queue { $0.replacingOccurrences(of: #""desktopOnly":false"#, with: #""desktopOnly":0"#) },
            "missing relatedRuleIds": queue { $0.replacingOccurrences(of: #""relatedRuleIds":[],"#, with: "") },
            "evidence id with a dot": queue { $0.replacingOccurrences(of: #"{"id":"1","at""#, with: #"{"id":"1.0","at""#) },
            "rule missing a nullable field": library { $0.replacingOccurrences(of: #""editedAt":null,"#, with: "") },
            "rule editedOn unknown": library { $0.replacingOccurrences(of: #""editedOn":null"#, with: #""editedOn":"tablet""#) },
            "rule state unknown": library { $0.replacingOccurrences(of: #""state":"on""#, with: #""state":"maybe""#) },
            "rule source unknown": library { $0.replacingOccurrences(of: #""source":"learned""#, with: #""source":"guessed""#) },
            "schema 0": queueJSON(storeVersion: 42).replacingOccurrences(of: #""schema":1"#, with: #""schema":0"#),
            "schema 65536": queueJSON(storeVersion: 42).replacingOccurrences(of: #""schema":1"#, with: #""schema":65536"#),
            "storeVersion negative": queueJSON(storeVersion: -1),
            "weekStart not a date": good["counts"]!.replacingOccurrences(of: "2026-11-16", with: "2026-11-6"),
            "thirteen weeks": good["counts"]!.replacingOccurrences(of: #"[{"weekStart":"2026-11-16","repeatCorrections":6,"violations":2}]"#, with: "[" + Array(repeating: #"{"weekStart":"2026-11-16","repeatCorrections":6,"violations":2}"#, count: 13).joined(separator: ",") + "]"),
            "removed state with words": good["evidence"]!.replacingOccurrences(of: #""state":"removed","words":null"#, with: #""state":"removed","words":"x""#),
            "words over 300": good["evidence"]!.replacingOccurrences(of: "Headings again, only the first word gets a capital.", with: String(repeating: "w", count: 301)),
            "rationale over 1000": good["evidence"]!.replacingOccurrences(of: "Three corrections ask for sentence case.", with: String(repeating: "r", count: 1001)),
            "rationale missing": good["evidence"]!.replacingOccurrences(of: #""rationale":"Three corrections ask for sentence case.","#, with: ""),
            "decision text empty": good["decision"]!.replacingOccurrences(of: "Use sentence case in every heading.", with: ""),
            "decision text over 500": good["decision"]!.replacingOccurrences(of: "Use sentence case in every heading.", with: String(repeating: "t", count: 501)),
            "decision text missing": good["decision"]!.replacingOccurrences(of: #""text":"Use sentence case in every heading.","#, with: ""),
            "decision unknown action": good["decision"]!.replacingOccurrences(of: #""action":"approve""#, with: #""action":"archive""#),
            "decision scope option bad": good["decision"]!.replacingOccurrences(of: #""scopeOptionId":"s3""#, with: #""scopeOptionId":"s 3""#),
            "sync have without library": good["sync"]!.replacingOccurrences(of: #","library":null"#, with: ""),
            "evidence-request short key": good["evidence-request"]!.replacingOccurrences(of: key, with: String(key.dropLast())),
            "error detail over 200": good["error"]!.replacingOccurrences(of: "flags do not match the type", with: String(repeating: "d", count: 201)),
            "notice text over 600": good["notice"]!.replacingOccurrences(of: "Use sentence case in headings.", with: String(repeating: "n", count: 601)),
            "pair-refuse unknown reason": good["pair-refuse"]!.replacingOccurrences(of: "wrongCode", with: "tired"),
            "acknowledgement current of the wrong shape": good["acknowledgement rule"]!.replacingOccurrences(of: #""targetType":"rule","rule""#, with: #""targetType":"rule","draft""#),
            "not an object": "[]",
            "type missing": #"{"id":"\#(id)","sentAt":\#(t)}"#,
        ]
        for (name, json) in refusals {
            XCTAssertThrowsError(try decode(json), name)
        }
    }

    func testLengthsCountCodePointsAsJSONSchemaDoes() throws {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"  // one grapheme cluster, five code points
        XCTAssertEqual(family.count, 1)
        XCTAssertEqual(family.unicodeScalars.count, 5)
        func decision(_ text: String) -> String {
            good["decision"]!.replacingOccurrences(of: "Use sentence case in every heading.", with: text)
        }
        XCTAssertNoThrow(try decode(decision(String(repeating: family, count: 100))), "500 code points")
        XCTAssertThrowsError(try decode(decision(String(repeating: family, count: 100) + "a")), "501 code points in 101 characters")
        XCTAssertNoThrow(try decode(decision(String(repeating: "\u{1F600}", count: 500))), "500 emoji")
    }

    func testRefusesInvalidUTF8() {
        var bytes = Data(#"{"type":"unpair","id":"\#(id)","sentAt":1,"x":""#.utf8)
        bytes.append(contentsOf: [0xFF, 0xFE])
        bytes.append(contentsOf: Data(#""}"#.utf8))
        XCTAssertThrowsError(try SyncMessage.decode(bytes)) { error in
            XCTAssertEqual((error as? MessageDecodingError)?.code, .badMessage)
        }
    }

    func testEncodingRoundTripsAndKeepsNulls() throws {
        for (name, json) in good {
            let message = try decode(json)
            let encoded = try message.encoded()
            XCTAssertEqual(try SyncMessage.decode(encoded), message, name)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            XCTAssertEqual(object["type"] as? String, message.type.rawValue, name)
        }
        let sync = String(decoding: try decode(good["sync"]!).encoded(), as: UTF8.self)
        XCTAssertTrue(sync.contains(#""library":null"#))
        let applied = String(decoding: try decode(good["acknowledgement applied"]!).encoded(), as: UTF8.self)
        XCTAssertTrue(applied.contains(#""reason":null"#) && applied.contains(#""current":null"#))
    }

    func testEncodingRefusesAnInvalidMessage() {
        let message = SyncMessage.unpair(Unpair(id: "short", sentAt: 1))
        XCTAssertThrowsError(try message.encoded()) { error in XCTAssertEqual((error as? ValidationError)?.path, "id") }
    }

    func testRoutesOfTable20() {
        let routes: [MessageType: (EnvelopeKind, EnvelopeFlags, UInt8)] = [
            .pairRequest: (.pairRequest, [], 0), .pairReceived: (.pairReply, [], 1), .pairAccept: (.pairReply, [], 0),
            .pairRefuse: (.pairReply, [], 0), .queue: (.message, .mailbox, 1), .library: (.message, .mailbox, 2),
            .counts: (.message, [], 0), .evidence: (.message, .replyKey, 0), .acknowledgement: (.message, .mailbox, 0),
            .decision: (.message, .mailbox, 0), .sync: (.message, [], 0), .evidenceRequest: (.message, [], 0),
            .unpair: (.message, .mailbox, 0), .error: (.message, [], 0), .notice: (.push, [], 0),
            .countUpdate: (.push, [], 1),
        ]
        XCTAssertEqual(routes.count, MessageType.allCases.count)
        for (type, route) in routes {
            XCTAssertEqual(type.kind, route.0, type.rawValue)
            XCTAssertEqual(type.flags, route.1, type.rawValue)
            XCTAssertEqual(type.slot, route.2, type.rawValue)
        }
    }
}
