import Crypto
import Foundation
@testable import LastideKit
import XCTest

final class PCSessionTests: XCTestCase {
    var f = PairedFixture()

    func evidenceJSON(requestId: String) -> String {
        #"{"type":"evidence","id":"\#(makeMessageID())","sentAt":\#(sampleTime),"requestId":"\#(requestId)","draftId":"d-0001","changedAtStoreVersion":41,"rationale":null,"items":[{"evidenceId":"1","state":"words","words":"Headings again."},{"evidenceId":"2","state":"removed","words":null}]}"#
    }

    func testPhoneSealsEveryPhoneMessageWithTheFlagsAndSlotOfTable20() throws {
        let decision = Decision(id: makeMessageID(), sentAt: sampleTime, decisionId: makeMessageID(),
                                target: Target(targetType: .draft, id: "d-0001"), storeVersion: 42, action: .approve,
                                text: nil, scopeOptionId: "s3", decidedAt: sampleTime)
        let messages: [SyncMessage] = [
            .decision(decision),
            .sync(SyncRequest(id: makeMessageID(), sentAt: sampleTime, schema: 1, have: SnapshotVersions(queue: 41, library: nil))),
            .evidenceRequest(f.session.makeEvidenceRequest(draftID: "d-0001", storeVersion: 42, now: sampleTime)),
            .unpair(Unpair(id: makeMessageID(), sentAt: sampleTime)),
            .error(ErrorMessage(id: makeMessageID(), sentAt: sampleTime, inReplyTo: nil, code: .badMessage, detail: "x")),
        ]
        var lastSeq = f.session.record.lastSentSeq
        for message in messages {
            let sealed = try f.session.seal(message, now: sampleTime)
            XCTAssertGreaterThan(sealed.seq, lastSeq)
            lastSeq = sealed.seq
            XCTAssertEqual(f.session.record.lastSentSeq, sealed.seq)
            let (header, plaintext) = try f.pc.openMessage(sealed.bytes, from: f.phoneKey.publicKey)
            XCTAssertEqual(header.kind, .message)
            XCTAssertEqual(header.flags, message.type.flags)
            XCTAssertEqual(header.slot, message.type.slot)
            XCTAssertEqual(header.sender, f.phoneID)
            XCTAssertEqual(header.recipient, .pc)
            XCTAssertNil(relayHeaderCheck(sealed.bytes))
            XCTAssertEqual(try SyncMessage.decode(plaintext), message)
        }
        // A decision's nulls travel as explicit nulls.
        let plaintext = try f.pc.openMessage(try f.session.seal(.decision(decision), now: sampleTime).bytes,
                                             from: f.phoneKey.publicKey).1
        XCTAssertTrue(String(decoding: plaintext, as: UTF8.self).contains(#""text":null"#))
    }

    func testNotesThePCSchemaAndLastSeenTimeInTheRecord() throws {
        XCTAssertEqual(f.session.record.pcSchema, 1)
        XCTAssertNil(f.session.record.pcLastSeenAt)
        f.session.notePCSchema(2)
        f.session.notePCLastSeen(at: sampleTime + 5_000)
        XCTAssertEqual(f.session.record.pcSchema, 2)
        XCTAssertEqual(f.session.record.pcLastSeenAt, sampleTime + 5_000)
        let decoded = try JSONDecoder().decode(PairingRecord.self, from: JSONEncoder().encode(f.session.record))
        XCTAssertEqual(decoded, f.session.record)
    }

    func testAcceptsAPCMessageOnceAndReportsReplays() throws {
        let frame = try f.fromPC(queueJSON(storeVersion: 42), flags: .mailbox, slot: 1)
        let seq = try EnvelopeHeader(frame: frame).seq
        guard case .message(.queue, let report) = f.session.receive(frame, now: sampleTime) else { return XCTFail("not accepted") }
        XCTAssertEqual(report, ReceivedReport(from: .pc, upTo: seq))
        XCTAssertEqual(f.session.record.lastRecvSeq, seq)
        XCTAssertEqual(report.controlFrame, #"{"from":"AAAAAAAAAAAAAAAAAAAAAA","op":"received","upTo":\#(seq)}"#)
        guard case .duplicate(let again) = f.session.receive(frame, now: sampleTime) else { return XCTFail("replay accepted") }
        XCTAssertEqual(again.upTo, seq)
    }

    func testDropsAnOlderEnvelopeAsADuplicate() throws {
        let older = try f.fromPC(queueJSON(storeVersion: 41), flags: .mailbox, slot: 1)
        let newer = try f.fromPC(queueJSON(storeVersion: 42), flags: .mailbox, slot: 1)
        guard case .message = f.session.receive(newer, now: sampleTime) else { return XCTFail("not accepted") }
        guard case .duplicate = f.session.receive(older, now: sampleTime) else { return XCTFail("older accepted") }
    }

    func testIgnoresFramesThatDoNotProveTheirSender() throws {
        let start = f.session.record.lastRecvSeq
        func assertIgnored(_ frame: Data, _ name: String) {
            guard case .ignored = f.session.receive(frame, now: sampleTime) else { return XCTFail(name) }
        }
        let good = try f.fromPC(queueJSON(storeVersion: 42), flags: .mailbox, slot: 1)
        assertIgnored(Data(good.prefix(91)), "short frame")
        var tampered = good
        tampered[tampered.count - 1] ^= 1
        assertIgnored(tampered, "tampered ciphertext")
        var flippedHeader = good
        flippedHeader[3] = 2
        assertIgnored(flippedHeader, "slot changed by the relay")
        assertIgnored(try f.pc.seal(queueJSON(storeVersion: 42), flags: .mailbox, slot: 1, to: DeviceID.random(),
                                    recipientKey: f.phoneKey.publicKey, info: Labels.messageInfo(f.pc.pairingID)),
                      "another recipient")
        assertIgnored(try f.pc.seal(queueJSON(storeVersion: 42), flags: .mailbox, slot: 1, to: f.phoneID,
                                    recipientKey: f.phoneKey.publicKey, info: Labels.messageInfo(f.pc.pairingID),
                                    sender: DeviceID.random()), "another sender id")
        assertIgnored(try f.pc.seal(queueJSON(storeVersion: 42), flags: .mailbox, slot: 1, to: f.phoneID,
                                    recipientKey: f.phoneKey.publicKey, info: Labels.messageInfo(f.pc.pairingID),
                                    senderKey: Curve25519.KeyAgreement.PrivateKey()), "a key other than the PC key")
        assertIgnored(try f.pc.seal(queueJSON(storeVersion: 42), flags: .mailbox, slot: 1, to: f.phoneID,
                                    recipientKey: f.phoneKey.publicKey, info: Labels.pushInfo(f.pc.pairingID)), "another info")
        assertIgnored(try f.pc.seal(#"{"type":"notice"}"#, kind: .push, to: f.phoneID, recipientKey: f.phoneKey.publicKey,
                                    info: Labels.pushInfo(f.pc.pairingID)), "kind 4 on the socket")
        assertIgnored(try f.pc.seal(queueJSON(storeVersion: 42), kind: .pairReply, to: f.phoneID,
                                    recipientKey: f.phoneKey.publicKey, info: Labels.messageInfo(f.pc.pairingID)), "kind 2")
        assertIgnored(try f.fromPC(evidenceJSON(requestId: sampleID), flags: .replyKey), "REPLY_KEY without a waiting key")
        XCTAssertEqual(f.session.record.lastRecvSeq, start, "no ignored frame moves lastRecvSeq")
    }

    func testAnswersUnusableMessagesWithTheErrorCodesOfTable12() throws {
        func outcome(_ json: String, flags: EnvelopeFlags = [], slot: UInt8 = 0) throws -> (ErrorMessage?, ReceivedReport) {
            let frame = try f.fromPC(json, flags: flags, slot: slot)
            guard case .unusable(let reply, let report) = f.session.receive(frame, now: sampleTime + 1) else {
                XCTFail("not unusable: \(json)")
                return (nil, ReceivedReport(from: .pc, upTo: 0))
            }
            XCTAssertEqual(report.upTo, try EnvelopeHeader(frame: frame).seq)
            XCTAssertEqual(f.session.record.lastRecvSeq, report.upTo, "an unusable message still leaves the mailbox")
            return (reply, report)
        }
        XCTAssertEqual(try outcome("not json").0?.code, .badMessage)
        XCTAssertEqual(try outcome("[1,2]").0?.code, .badMessage)
        XCTAssertEqual(try outcome(#"{"id":"\#(sampleID)"}"#).0?.code, .badMessage)
        XCTAssertEqual(try outcome(#"{"type":7}"#).0?.code, .badMessage)
        let unknown = try outcome(#"{"type":"hello","id":"\#(sampleID)","sentAt":1}"#).0
        XCTAssertEqual(unknown?.code, .unknownType)
        XCTAssertEqual(unknown?.inReplyTo, sampleID)
        let schema = try outcome(#"{"type":"counts","id":"\#(sampleID)","sentAt":1}"#).0
        XCTAssertEqual(schema?.code, .badMessage)
        XCTAssertEqual(schema?.inReplyTo, sampleID)
        XCTAssertEqual(schema?.sentAt, sampleTime + 1)
        XCTAssertEqual(try outcome(queueJSON(storeVersion: 42), flags: [], slot: 0).0?.code, .badMessage, "queue without MAILBOX")
        XCTAssertEqual(try outcome(queueJSON(storeVersion: 42), flags: .mailbox, slot: 2).0?.code, .badMessage, "queue in slot 2")
        let decision = #"{"type":"decision","id":"\#(sampleID)","sentAt":1,"decisionId":"\#(sampleID)","target":{"targetType":"draft","id":"d-1"},"storeVersion":1,"action":"reject","text":null,"scopeOptionId":null,"decidedAt":1}"#
        XCTAssertEqual(try outcome(decision, flags: .mailbox).0?.code, .badMessage, "a phone type from the PC")
        let pairAccept = #"{"type":"pair-accept","id":"\#(sampleID)","sentAt":1,"pairingId":"\#(sampleID)","phoneId":"\#(sampleID)","phoneToken":"wNyCnzt7VOyDm3kXBykkPeZ6sf8Dtg_lDgVNdkaVVPY","pcName":"My PC","schema":1,"features":["mailbox"]}"#
        XCTAssertEqual(try outcome(pairAccept).0?.code, .badMessage, "a kind 2 type in kind 3")
        XCTAssertEqual(try outcome(evidenceJSON(requestId: sampleID)).0?.code, .badMessage, "evidence without REPLY_KEY")
        let error = #"{"type":"error","id":"\#(sampleID)","sentAt":1,"inReplyTo":null,"code":"badMessage","detail":"x"}"#
        XCTAssertNil(try outcome(error, flags: .mailbox).0, "an error never draws an error")
        XCTAssertNil(try outcome(#"{"type":"error","id":"\#(sampleID)","sentAt":1}"#).0, "a broken error never draws an error")
    }

    func testAcceptsAnErrorFromThePC() throws {
        let error = #"{"type":"error","id":"\#(sampleID)","sentAt":1,"inReplyTo":"\#(sampleID)","code":"unknownType","detail":"x"}"#
        guard case .message(.error(let message), _) = f.session.receive(try f.fromPC(error), now: sampleTime) else {
            return XCTFail("not accepted")
        }
        XCTAssertEqual(message.code, .unknownType)
    }

    func testOpensEvidenceWithTheNewestMatchingReplyKeyAndForgetsKeysOnDrop() throws {
        let first = f.session.makeEvidenceRequest(draftID: "d-0001", storeVersion: 42, now: sampleTime)
        let second = f.session.makeEvidenceRequest(draftID: "d-0002", storeVersion: 42, now: sampleTime)
        XCTAssertEqual(f.session.waitingReplyKeyCount, 2)
        for request in [second, first] {
            let replyKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: Base64URL.decode(request.replyKey, byteCount: 32))
            let frame = try f.fromPC(evidenceJSON(requestId: request.id), flags: .replyKey, recipientKey: replyKey)
            guard case .message(.evidence(let evidence), _) = f.session.receive(frame, now: sampleTime) else {
                return XCTFail("evidence did not open")
            }
            XCTAssertEqual(evidence.requestId, request.id)
            XCTAssertEqual(evidence.items.first?.words, "Headings again.")
        }
        let replyKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: Base64URL.decode(first.replyKey, byteCount: 32))
        let late = try f.fromPC(evidenceJSON(requestId: first.id), flags: .replyKey, recipientKey: replyKey)
        f.session.dropReplyKeys()
        XCTAssertEqual(f.session.waitingReplyKeyCount, 0)
        guard case .ignored = f.session.receive(late, now: sampleTime) else { return XCTFail("opened after the drop") }
    }

    func testQueueSealedToThePhoneKeyWithREPLYKEYIsIgnored() throws {
        _ = f.session.makeEvidenceRequest(draftID: "d-0001", storeVersion: 42, now: sampleTime)
        guard case .ignored = f.session.receive(try f.fromPC(queueJSON(storeVersion: 42), flags: .replyKey), now: sampleTime) else {
            return XCTFail("a frame sealed to the phone key opened with a reply key")
        }
    }
}
