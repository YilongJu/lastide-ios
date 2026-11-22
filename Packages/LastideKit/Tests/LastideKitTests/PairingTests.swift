import Crypto
import Foundation
@testable import LastideKit
import XCTest

final class QRPayloadTests: XCTestCase {
    let good = "lastide-pair:1?k=Ot3-WtJguKG96IqpphPn5Ay56Zmu86xNwiWGVTU3U08&p=NCvG0FBkatktbCilgU7GqA&t=Gs9iGMo0pL0yJjqBIYT9KA&r=https%3A%2F%2Frelay.example"
    let k = "Ot3-WtJguKG96IqpphPn5Ay56Zmu86xNwiWGVTU3U08", p = "NCvG0FBkatktbCilgU7GqA", t = "Gs9iGMo0pL0yJjqBIYT9KA"

    func parse(_ text: String, origins: [String] = [relayOrigin]) throws -> QRPayload { try QRPayload.parse(text, relayOrigins: origins) }

    func assertRefused(_ text: String, _ expected: QRError = .notPairingCode, origins: [String] = [relayOrigin],
                       file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try parse(text, origins: origins), file: file, line: line) { error in
            XCTAssertEqual(error as? QRError, expected, text, file: file, line: line)
        }
    }

    func testParsesTheExample() throws {
        let payload = try parse(good)
        XCTAssertEqual(payload.pairingID.base64url, p)
        XCTAssertEqual(payload.ticket.base64url, t)
        XCTAssertEqual(payload.relayOrigin, "https://relay.example")
        XCTAssertEqual(payload.socketURL.absoluteString, "wss://relay.example/api/relay/\(p)")
        XCTAssertEqual(good.count, 140)
    }

    func testKeepsAnExplicitPortInTheSocketURL() throws {
        let origin = "https://relay.example:8443"
        let payload = try parse("lastide-pair:1?k=\(k)&p=\(p)&t=\(t)&r=https%3A%2F%2Frelay.example%3A8443", origins: [origin])
        XCTAssertEqual(payload.socketURL.absoluteString, "wss://relay.example:8443/api/relay/\(p)")
    }

    func testRefusesANonCanonicalPercentEncodingOfTheOrigin() {
        assertRefused("lastide-pair:1?k=\(k)&p=\(p)&t=\(t)&r=https%3a%2f%2frelay.example")
        assertRefused("lastide-pair:1?k=\(k)&p=\(p)&t=\(t)&r=https%3A%2F%2Frelay%2Eexample")
    }

    func testRefusesAnotherVersionWithTheUpdateSentence() {
        assertRefused(good.replacingOccurrences(of: "lastide-pair:1?", with: "lastide-pair:2?"), .otherVersion)
        assertRefused(good.replacingOccurrences(of: "lastide-pair:1?", with: "lastide-pair:12?"), .otherVersion)
        XCTAssertEqual(QRError.otherVersion.displayText, "Update the Lastide app to pair with this PC.")
        XCTAssertEqual(QRError.notPairingCode.displayText, "This is not a Lastide pairing code.")
    }

    func testRefusesEveryOtherString() {
        let r = "https%3A%2F%2Frelay.example"
        let cases = [
            "", "https://relay.example", "lastide-pair:", "lastide-pair:x?k=\(k)", "LASTIDE-PAIR:1?k=\(k)&p=\(p)&t=\(t)&r=\(r)",
            "lastide-pair:1?p=\(p)&k=\(k)&t=\(t)&r=\(r)",
            "lastide-pair:1?k=\(k)&p=\(p)&t=\(t)",
            "lastide-pair:1?k=\(k)&p=\(p)&t=\(t)&r=\(r)&x=1",
            "lastide-pair:1?k=\(k)&k=\(k)&t=\(t)&r=\(r)",
            "lastide-pair:1?k=\(k)=&p=\(p)&t=\(t)&r=\(r)",
            "lastide-pair:1?k=\(k.dropLast())&p=\(p)&t=\(t)&r=\(r)",
            "lastide-pair:1?k=\(k.dropLast())1&p=\(p)&t=\(t)&r=\(r)",
            "lastide-pair:1?k=\(k)&p=\(p.dropLast())B&t=\(t)&r=\(r)",
            "lastide-pair:1?k=\(k)&p=\(p)&t=\(t)==&r=\(r)",
            "lastide-pair:1?k=\(k)&p=\(p)&t=\(t)&r=https%3A%2F%2Fother.example",
            "lastide-pair:1?k=\(k)&p=\(p)&t=\(t)&r=https://relay.example",
            "lastide-pair:1?k=\(k)&p=\(p)&t=\(t)&r=https%3a%2f%2frelay.example",
            "lastide-pair:1?k=\(k)&p=\(p)&t=\(t)&r=https%3A%2F%2Frelay.example%2F",
            "lastide-pair:1?k=\(k)&p=\(p)&t=\(t)&r=https%3A%2F%2Frelay.example%2Fapi",
            "lastide-pair:1?k=\(k)&p=\(p)&t=\(t)&r=http%3A%2F%2Frelay.example",
            "lastide-pair:1?k=\(k)&p=\(p)&t=\(t)&r=https%3A%2F%2FRELAY.example",
            "lastide-pair:1?k=\(k)&p=\(p)&t=\(t)&r=https%3A%2F%2Fuser%40relay.example",
            "lastide-pair:1?k=\(k)&p=\(p)&t=\(t)&r=https%3A%2F%2Frelay.example%3A443",
            "lastide-pair:1?k=\(k)&p=\(p)&t=\(t)&r=https%3A%2F%2Frelay.example%3Fx",
            "lastide-pair:1?k=\(k)&p=\(p)&t=\(t)&r=https%3A%2F%2Frelay.example%23x",
            "lastide-pair:1?k=\(k)&p=\(p)&t=\(t)&r=https%3A%2F%2Frelay.example%ZZ",
            "lastide-pair:1?k=\(k)&p=\(p)&t=\(t)&r=\(r) ",
        ]
        for text in cases { assertRefused(text) }
    }

    func testRefusesAnOriginLongerThan64EncodedCharacters() {
        let host = String(repeating: "a", count: 48) + ".example"
        let origin = "https://" + host
        let encoded = "https%3A%2F%2F" + host
        XCTAssertGreaterThan(encoded.count, 64)
        assertRefused("lastide-pair:1?k=\(k)&p=\(p)&t=\(t)&r=\(encoded)", origins: [origin])
    }

    func testEncodeURIComponentMatchesJavaScript() {
        XCTAssertEqual(QRPayload.encodeURIComponent("https://relay.example:8443"), "https%3A%2F%2Frelay.example%3A8443")
        XCTAssertEqual(QRPayload.encodeURIComponent("a-_.!~*'()b"), "a-_.!~*'()b")
    }

    func testExpiryAndRefusedTicketSentences() {
        XCTAssertEqual(RelayCloseCode.unauthorized.displayText(pairing: true), "This code no longer works. Show a new code on your PC.")
        XCTAssertEqual(RelayCloseCode.unauthorized.displayText(pairing: false), "This PC no longer accepts this phone.")
        XCTAssertEqual(RelayCloseCode.pcOffline.displayText(pairing: true), "Open Lastide on your PC and show a new code.")
    }
}

final class PhonePairingTests: XCTestCase {
    var pc = FakePC()

    func start() throws -> PhonePairing {
        let payload = try QRPayload.parse(pc.qr, relayOrigins: [relayOrigin])
        return try PhonePairing(payload: payload, deviceName: "iPhone", model: "iPhone17,3",
                                app: AppInfo(version: "1.0", build: 1), consentAcceptedAt: sampleTime - 5_000, now: sampleTime)
    }

    func pairReceived(_ pairing: PhonePairing, pairingId: String? = nil, phoneId: String? = nil, slot: UInt8 = 1,
                      h1: Data? = nil, senderKey: Curve25519.KeyAgreement.PrivateKey? = nil) throws -> (Data, CheckCode) {
        let json = #"{"type":"pair-received","id":"\#(makeMessageID())","sentAt":\#(sampleTime),"pairingId":"\#(pairingId ?? pc.pairingID.base64url)","phoneId":"\#(phoneId ?? pairing.phoneID.base64url)"}"#
        let info = Labels.pairReplyInfo(h1: h1 ?? pairing.h1)
        var sender = try HPKE.Sender(recipientKey: pairing.phoneKey.publicKey, ciphersuite: LastideProtocol.ciphersuite,
                                     info: info, authenticatedBy: senderKey ?? pc.key)
        let code = CheckCode(exported: try sender.exportSecret(context: Labels.checkCodeContext(h1: pairing.h1), outputByteCount: 8)
            .withUnsafeBytes { Data($0) })
        let header = try EnvelopeHeader(kind: .pairReply, flags: [], slot: slot, sender: .pc, recipient: pairing.phoneID,
                                        seq: pc.nextSeq(), enc: sender.encapsulatedKey).bytes
        return (header + (try sender.seal(Data(json.utf8), authenticating: header)), code)
    }

    func reply(_ pairing: PhonePairing, _ json: String, slot: UInt8 = 0) throws -> Data {
        try pc.seal(json, kind: .pairReply, slot: slot, to: pairing.phoneID, recipientKey: pairing.phoneKey.publicKey,
                    info: Labels.pairReplyInfo(h1: pairing.h1))
    }

    func acceptJSON(_ pairing: PhonePairing, pairingId: String? = nil) -> String {
        #"{"type":"pair-accept","id":"\#(makeMessageID())","sentAt":\#(sampleTime),"pairingId":"\#(pairingId ?? pc.pairingID.base64url)","phoneId":"\#(pairing.phoneID.base64url)","phoneToken":"wNyCnzt7VOyDm3kXBykkPeZ6sf8Dtg_lDgVNdkaVVPY","pcName":"My PC","schema":1,"features":["mailbox"]}"#
    }

    func refuseJSON(_ pairing: PhonePairing, _ reason: String) -> String {
        #"{"type":"pair-refuse","id":"\#(makeMessageID())","sentAt":\#(sampleTime),"pairingId":"\#(pc.pairingID.base64url)","phoneId":"\#(pairing.phoneID.base64url)","reason":"\#(reason)"}"#
    }

    func assertDropped(_ pairing: inout PhonePairing, _ frame: Data, _ expected: PairingError? = nil,
                       file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try pairing.receive(frame, now: sampleTime), file: file, line: line) { error in
            guard let error = error as? PairingError else { return XCTFail("not a PairingError", file: file, line: line) }
            if let expected { XCTAssertEqual(error, expected, file: file, line: line) }
        }
    }

    func testFullPairingRoundTrip() throws {
        var pairing = try start()
        let (header, plaintext) = try pc.openPairRequest(pairing.pairRequestEnvelope)
        XCTAssertEqual(header.kind, .pairRequest)
        XCTAssertEqual(header.flags, [])
        XCTAssertEqual(header.slot, 0)
        XCTAssertEqual(header.sender, pairing.phoneID)
        XCTAssertEqual(header.recipient, .pc)
        XCTAssertEqual(header.seq, UInt64(sampleTime))
        XCTAssertEqual(pairing.h1, Data(SHA256.hash(data: pairing.pairRequestEnvelope)))
        guard case .pairRequest(let request) = try SyncMessage.decode(plaintext) else { return XCTFail("not a pair request") }
        XCTAssertEqual(request.ticket, pc.ticket.base64url)
        XCTAssertEqual(request.phoneId, pairing.phoneID.base64url)
        XCTAssertEqual(request.phoneKey, Base64URL.encode(pairing.phoneKey.publicKey.rawRepresentation))
        XCTAssertEqual(request.consent.disclosure, "outside-ai-v1")
        XCTAssertEqual(request.schema, 2, "the phone sends the schema revision it speaks")

        let (received, pcCode) = try pairReceived(pairing)
        guard case .checkCode(let code) = try pairing.receive(received, now: sampleTime) else { return XCTFail("no code") }
        XCTAssertEqual(code, pcCode)

        let acceptFrame = try reply(pairing, acceptJSON(pairing))
        guard case .accepted(let result) = try pairing.receive(acceptFrame, now: sampleTime + 41_000) else {
            return XCTFail("not accepted")
        }
        XCTAssertEqual(result.record.relayOrigin, relayOrigin)
        XCTAssertEqual(result.record.pcKey, Base64URL.encode(pc.key.publicKey.rawRepresentation))
        XCTAssertEqual(result.record.lastSentSeq, UInt64(sampleTime))
        XCTAssertEqual(result.record.lastRecvSeq, try EnvelopeHeader(frame: acceptFrame).seq)
        XCTAssertEqual(result.phoneToken.count, 32)
        XCTAssertEqual(result.record.socketURL.absoluteString, "wss://relay.example/api/relay/\(pc.pairingID.base64url)")
        assertDropped(&pairing, try reply(pairing, acceptJSON(pairing)), .unexpectedFrame("the pairing already ended"))

        // The record survives a JSON round trip, as pairings.json stores it.
        let stored = try JSONDecoder().decode(PairingRecord.self, from: JSONEncoder().encode(result.record))
        XCTAssertEqual(stored, result.record)
    }

    func testEveryRefusalReasonEndsThePairing() throws {
        for reason in PairRefuseReason.allCases {
            var pairing = try start()
            if reason != .tooManyPhones { _ = try pairing.receive(pairReceived(pairing).0, now: sampleTime) }
            guard case .refused(let got) = try pairing.receive(reply(pairing, refuseJSON(pairing, reason.rawValue)), now: sampleTime)
            else { return XCTFail("not refused") }
            XCTAssertEqual(got, reason)
            assertDropped(&pairing, try reply(pairing, acceptJSON(pairing)))
        }
        XCTAssertEqual(PairRefuseReason.wrongCode.displayText, "The code did not match. Pairing stopped.")
        XCTAssertEqual(PairRefuseReason.tooManyPhones.displayText, "This PC has 8 phones. Remove one on the PC first.")
    }

    func testDropsAcceptBeforePairReceived() throws {
        var pairing = try start()
        assertDropped(&pairing, try reply(pairing, acceptJSON(pairing)), .unexpectedFrame("pair-accept before pair-received"))
    }

    func testDropsAReplyWhoseSeqIsNotAbovePairReceived() throws {
        var pairing = try start()
        let accept = try reply(pairing, acceptJSON(pairing))
        _ = try pairing.receive(pairReceived(pairing).0, now: sampleTime)
        assertDropped(&pairing, accept, .unexpectedFrame("seq not above pair-received"))
    }

    func testDropsASecondPairReceived() throws {
        var pairing = try start()
        _ = try pairing.receive(pairReceived(pairing).0, now: sampleTime)
        assertDropped(&pairing, try pairReceived(pairing).0, .unexpectedFrame("a second pair-received"))
    }

    func testDropsWrongIDsInThePlaintext() throws {
        var pairing = try start()
        let otherID = DeviceID.random().base64url
        assertDropped(&pairing, try pairReceived(pairing, pairingId: otherID).0, .wrongPairing)
        assertDropped(&pairing, try pairReceived(pairing, phoneId: otherID).0, .wrongPairing)
        _ = try pairing.receive(pairReceived(pairing).0, now: sampleTime)
        assertDropped(&pairing, try reply(pairing, acceptJSON(pairing, pairingId: otherID)), .wrongPairing)
    }

    func testDropsAReplyFromAnotherKeyOrForAnotherRequest() throws {
        var pairing = try start()
        assertDropped(&pairing, try pairReceived(pairing, senderKey: Curve25519.KeyAgreement.PrivateKey()).0, .openFailed)
        assertDropped(&pairing, try pairReceived(pairing, h1: Data(count: 32)).0, .openFailed)
    }

    func testDropsAMessageInTheWrongSlotOrKind() throws {
        var pairing = try start()
        assertDropped(&pairing, try pairReceived(pairing, slot: 0).0)
        assertDropped(&pairing, try reply(pairing, acceptJSON(pairing), slot: 1))
        let messageKind = try pc.seal(acceptJSON(pairing), kind: .message, to: pairing.phoneID,
                                      recipientKey: pairing.phoneKey.publicKey, info: Labels.pairReplyInfo(h1: pairing.h1))
        assertDropped(&pairing, messageKind, .unexpectedFrame("not a pair reply"))
        let wrongRecipient = try pc.seal(acceptJSON(pairing), kind: .pairReply, to: DeviceID.random(),
                                         recipientKey: pairing.phoneKey.publicKey, info: Labels.pairReplyInfo(h1: pairing.h1))
        assertDropped(&pairing, wrongRecipient, .unexpectedFrame("wrong device ids"))
        assertDropped(&pairing, Data(count: 91), .unexpectedFrame("bad header"))
        // The pairing still completes after the dropped frames.
        _ = try pairing.receive(pairReceived(pairing).0, now: sampleTime)
        guard case .accepted = try pairing.receive(reply(pairing, acceptJSON(pairing)), now: sampleTime) else {
            return XCTFail("not accepted")
        }
    }

    func testRefusesABadPairRequestBeforeSealing() throws {
        let payload = try QRPayload.parse(pc.qr, relayOrigins: [relayOrigin])
        XCTAssertThrowsError(try PhonePairing(payload: payload, deviceName: "", model: "iPhone17,3",
                                              app: AppInfo(version: "1.0", build: 1), consentAcceptedAt: 0, now: sampleTime))
        XCTAssertThrowsError(try PhonePairing(payload: payload, deviceName: "iPhone", model: "iPhone 17",
                                              app: AppInfo(version: "1.0", build: 1), consentAcceptedAt: 0, now: sampleTime))
        XCTAssertThrowsError(try PhonePairing(payload: payload, deviceName: "iPhone", model: "iPhone17,3",
                                              app: AppInfo(version: "1.0", build: 0), consentAcceptedAt: 0, now: sampleTime))
    }
}
