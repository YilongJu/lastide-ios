import Crypto
import Foundation
@testable import LastideKit
import XCTest

/// RFC 9180 appendix A.2.1 and A.2.3 (Table 29, row 1).
final class RFC9180VectorTests: XCTestCase {
    func testBaseAndAuthEntriesOpenEveryEncryptionAndMatchEveryExport() throws {
        let entries = try XCTUnwrap(Vectors.object("rfc9180-a2") as? [[String: Any]])
        XCTAssertEqual(entries.map { $0["mode"] as? Int }, [0, 2])
        for entry in entries {
            XCTAssertEqual(entry["kem_id"] as? Int, 32)
            XCTAssertEqual(entry["kdf_id"] as? Int, 1)
            XCTAssertEqual(entry["aead_id"] as? Int, 3)
            let mode = try XCTUnwrap(entry["mode"] as? Int)
            let skR = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: hex(entry["skRm"]))
            XCTAssertEqual(skR.publicKey.rawRepresentation, try hex(entry["pkRm"]))
            let info = try hex(entry["info"]), enc = try hex(entry["enc"])
            var recipient: HPKE.Recipient
            if mode == 2 {
                let pkS = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: hex(entry["pkSm"]))
                recipient = try HPKE.Recipient(privateKey: skR, ciphersuite: .Curve25519_SHA256_ChachaPoly, info: info,
                                               encapsulatedKey: enc, authenticatedBy: pkS)
            } else {
                recipient = try HPKE.Recipient(privateKey: skR, ciphersuite: .Curve25519_SHA256_ChachaPoly, info: info,
                                               encapsulatedKey: enc)
            }
            let encryptions = try XCTUnwrap(entry["encryptions"] as? [[String: Any]])
            XCTAssertEqual(encryptions.count, 257)
            for item in encryptions {
                XCTAssertEqual(try recipient.open(hex(item["ct"]), authenticating: hex(item["aad"])), try hex(item["pt"]))
            }
            let exports = try XCTUnwrap(entry["exports"] as? [[String: Any]])
            XCTAssertEqual(exports.count, 3)
            for item in exports {
                let length = try XCTUnwrap(item["L"] as? Int)
                let value = try recipient.exportSecret(context: hex(item["exporter_context"]), outputByteCount: length)
                XCTAssertEqual(value.withUnsafeBytes { Data($0) }, try hex(item["exported_value"]))
            }
        }
    }

    func testBaseEntryAnchors() throws {
        let entries = try XCTUnwrap(Vectors.object("rfc9180-a2") as? [[String: Any]])
        XCTAssertTrue(try XCTUnwrap(entries[0]["pkRm"] as? String).hasPrefix("4310ee97"))
        XCTAssertTrue(try XCTUnwrap(entries[0]["enc"] as? String).hasPrefix("1afa08d3"))
    }
}

/// The Lastide vector of section 10.3 (Table 29, the rows marked for `LastideKit`).
final class LastideVectorTests: XCTestCase {
    var vector: [String: Any] = [:]
    var pcKey: Curve25519.KeyAgreement.PrivateKey!
    var phoneKey: Curve25519.KeyAgreement.PrivateKey!
    var pairingID: PairingID!
    var phoneID: DeviceID!

    override func setUpWithError() throws {
        vector = try XCTUnwrap(Vectors.object("lastide-v1") as? [String: Any])
        let keys = try XCTUnwrap(vector["keys"] as? [String: Any])
        pcKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: hex(keys["pcPrivateKey"]))
        phoneKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: hex(keys["phonePrivateKey"]))
        let ids = try XCTUnwrap(vector["ids"] as? [String: Any])
        pairingID = try PairingID(bytes: hex(ids["pairingId"]))
        phoneID = try DeviceID(bytes: hex(ids["phoneId"]))
    }

    func envelope(_ name: String) throws -> [String: Any] { try XCTUnwrap(vector[name] as? [String: Any]) }

    func payload() throws -> QRPayload { try QRPayload.parse(XCTUnwrap(vector["qr"] as? String), relayOrigins: [relayOrigin]) }

    func pairing() throws -> PhonePairing {
        let request = try envelope("pairRequest")
        return PhonePairing(payload: try payload(), phoneKey: phoneKey, phoneID: phoneID,
                            pairRequestEnvelope: try hex(request["envelope"]),
                            pairRequestSeq: UInt64(try XCTUnwrap(request["seq"] as? Int)))
    }

    func testQRMatchesKeysAndIDs() throws {
        let qr = try payload()
        let keys = try XCTUnwrap(vector["keys"] as? [String: Any])
        let ids = try XCTUnwrap(vector["ids"] as? [String: Any])
        XCTAssertEqual(qr.pcKey.rawRepresentation, try hex(keys["pcPublicKey"]))
        XCTAssertEqual(pcKey.publicKey.rawRepresentation, try hex(keys["pcPublicKey"]))
        XCTAssertEqual(phoneKey.publicKey.rawRepresentation, try hex(keys["phonePublicKey"]))
        XCTAssertEqual(qr.pairingID.bytes, try hex(ids["pairingId"]))
        XCTAssertEqual(qr.ticket.bytes, try hex(ids["ticket"]))
        XCTAssertEqual(qr.relayOrigin, vector["relayOrigin"] as? String)
        XCTAssertEqual(qr.socketURL.absoluteString, "wss://relay.example/api/relay/NCvG0FBkatktbCilgU7GqA")
    }

    func testInfoStringsAndAnchors() throws {
        XCTAssertEqual(Labels.pairRequestInfo(pairingID), try hex(envelope("pairRequest")["info"]))
        XCTAssertEqual(Labels.messageInfo(pairingID), try hex(envelope("message")["info"]))
        XCTAssertEqual(Labels.messageInfo(pairingID).hex, "6c6173746964652f76312f6d65737361676500342bc6d050646ad92d6c28a5814ec6a8")
        let h1 = try hex(envelope("pairRequest")["envelopeSha256"])
        XCTAssertEqual(h1.hex, "d27ef268dce5e1d6c1ae852d21c98561852206a0c85e5ebb7be355dc39dd6403")
        XCTAssertEqual(Labels.pairReplyInfo(h1: h1), try hex(envelope("pairReceived")["info"]))
        XCTAssertEqual(Labels.pairReplyInfo(h1: h1), try hex(envelope("pairAccept")["info"]))
        XCTAssertEqual(Labels.checkCodeContext(h1: h1), try hex(envelope("pairReceived")["exporterContext"]))
        XCTAssertEqual(Labels.pairRequestInfo(pairingID).count, 40)
        XCTAssertEqual(Labels.pairReplyInfo(h1: h1).count, 54)
        XCTAssertEqual(Labels.messageInfo(pairingID).count, 35)
        XCTAssertEqual(Labels.pushInfo(pairingID).count, 32)
        XCTAssertEqual(Labels.checkCodeContext(h1: h1).count, 54)
    }

    func testEveryEnvelopeHeaderParsesAndRebuilds() throws {
        for name in ["pairRequest", "pairReceived", "pairAccept", "message"] {
            let entry = try envelope(name)
            let bytes = try hex(entry["envelope"])
            let header = try EnvelopeHeader(frame: bytes)
            XCTAssertEqual(header.bytes, try hex(entry["aad"]), name)
            XCTAssertEqual(header.kind.rawValue, UInt8(try XCTUnwrap(entry["kind"] as? Int)), name)
            XCTAssertEqual(header.flags.rawValue, UInt8(try XCTUnwrap(entry["flags"] as? Int)), name)
            XCTAssertEqual(header.slot, UInt8(try XCTUnwrap(entry["slot"] as? Int)), name)
            XCTAssertEqual(header.seq, UInt64(try XCTUnwrap(entry["seq"] as? Int)), name)
            XCTAssertEqual(header.enc, try hex(entry["enc"]), name)
            XCTAssertEqual(Data(SHA256.hash(data: bytes)), try hex(entry["envelopeSha256"]), name)
            XCTAssertNil(relayHeaderCheck(bytes), name)
        }
    }

    func testPCOpensThePairRequest() throws {
        let entry = try envelope("pairRequest")
        let bytes = try hex(entry["envelope"])
        let header = try EnvelopeHeader(frame: bytes)
        var recipient = try HPKE.Recipient(privateKey: pcKey, ciphersuite: LastideProtocol.ciphersuite,
                                           info: Labels.pairRequestInfo(pairingID), encapsulatedKey: header.enc)
        let plaintext = try recipient.open(bytes.dropFirst(76), authenticating: header.bytes)
        XCTAssertEqual(String(decoding: plaintext, as: UTF8.self), entry["plaintext"] as? String)
        guard case .pairRequest(let request) = try SyncMessage.decode(plaintext) else { return XCTFail("not a pair request") }
        XCTAssertEqual(request.phoneId, phoneID.base64url)
        XCTAssertEqual(request.phoneKey, Base64URL.encode(phoneKey.publicKey.rawRepresentation))
    }

    func testPhoneOpensPairReceivedAndDerivesTheCheckCode() throws {
        var pairing = try pairing()
        let entry = try envelope("pairReceived")
        guard case .checkCode(let code) = try pairing.receive(hex(entry["envelope"]), now: sampleTime) else {
            return XCTFail("no check code")
        }
        XCTAssertEqual(code.digits, entry["checkCode"] as? String)
        XCTAssertEqual(code.digits, "714390")
        XCTAssertEqual(code.display, "714 390")
        // The exported value itself, from a recipient context like the phone's.
        let bytes = try hex(entry["envelope"])
        let header = try EnvelopeHeader(frame: bytes)
        var recipient = try HPKE.Recipient(privateKey: phoneKey, ciphersuite: LastideProtocol.ciphersuite,
                                           info: hex(entry["info"]), encapsulatedKey: header.enc,
                                           authenticatedBy: pcKey.publicKey)
        XCTAssertEqual(String(decoding: try recipient.open(bytes.dropFirst(76), authenticating: header.bytes), as: UTF8.self),
                       entry["plaintext"] as? String)
        let exported = try recipient.exportSecret(context: hex(entry["exporterContext"]), outputByteCount: 8)
        XCTAssertEqual(exported.withUnsafeBytes { Data($0) }, try hex(entry["exportedValue"]))
    }

    func testPhoneOpensPairAcceptAndBuildsItsRecord() throws {
        var pairing = try pairing()
        _ = try pairing.receive(hex(envelope("pairReceived")["envelope"]), now: sampleTime)
        let accept = try envelope("pairAccept")
        guard case .accepted(let result) = try pairing.receive(hex(accept["envelope"]), now: 1_794_992_441_500) else {
            return XCTFail("not accepted")
        }
        let ids = try XCTUnwrap(vector["ids"] as? [String: Any])
        XCTAssertEqual(result.phoneToken, try hex(ids["phoneToken"]))
        XCTAssertEqual(result.record.pcName, "My PC")
        XCTAssertEqual(result.record.pcSchema, 1)
        XCTAssertEqual(result.record.features, [.mailbox])
        XCTAssertEqual(result.record.pairingId, pairingID)
        XCTAssertEqual(result.record.phoneId, phoneID)
        XCTAssertEqual(result.record.lastRecvSeq, UInt64(try XCTUnwrap(accept["seq"] as? Int)))
        XCTAssertEqual(result.record.lastSentSeq, UInt64(try XCTUnwrap(envelope("pairRequest")["seq"] as? Int)))
        XCTAssertEqual(result.record.pairedAt, 1_794_992_441_500)
    }

    func testPhoneOpensTheQueueMessageAndValidatesIt() throws {
        var pairing = try pairing()
        _ = try pairing.receive(hex(envelope("pairReceived")["envelope"]), now: sampleTime)
        guard case .accepted(let result) = try pairing.receive(hex(envelope("pairAccept")["envelope"]), now: sampleTime) else {
            return XCTFail("not accepted")
        }
        var session = try PCSession(record: result.record, phoneKey: phoneKey)
        let entry = try envelope("message")
        guard case .message(let message, let report) = session.receive(try hex(entry["envelope"]), now: sampleTime) else {
            return XCTFail("the queue message did not open")
        }
        XCTAssertEqual(message, try SyncMessage.decode(Data(try XCTUnwrap(entry["plaintext"] as? String).utf8)))
        guard case .queue(let queue) = message else { return XCTFail("not a queue") }
        XCTAssertEqual(queue.storeVersion, 42)
        XCTAssertEqual(queue.drafts.first?.text, "Use sentence case in headings.")
        XCTAssertEqual(report.upTo, UInt64(try XCTUnwrap(entry["seq"] as? Int)))
        XCTAssertEqual(session.record.lastRecvSeq, report.upTo)
    }

    func testFlippingAnyHeaderBitMakesTheOpenRefuse() throws {
        let cases: [(String, Curve25519.KeyAgreement.PrivateKey, Curve25519.KeyAgreement.PublicKey?)] = [
            ("pairRequest", pcKey, nil),
            ("pairReceived", phoneKey, pcKey.publicKey),
            ("pairAccept", phoneKey, pcKey.publicKey),
            ("message", phoneKey, pcKey.publicKey),
        ]
        var refused = 0
        for (name, key, sender) in cases {
            let entry = try envelope(name)
            let bytes = try hex(entry["envelope"])
            let info = try hex(entry["info"])
            let ciphertext = bytes.dropFirst(76)
            func open(_ header: Data) throws -> Data {
                let enc = header.subdata(in: 44..<76)
                var recipient: HPKE.Recipient
                if let sender {
                    recipient = try HPKE.Recipient(privateKey: key, ciphersuite: LastideProtocol.ciphersuite, info: info,
                                                   encapsulatedKey: enc, authenticatedBy: sender)
                } else {
                    recipient = try HPKE.Recipient(privateKey: key, ciphersuite: LastideProtocol.ciphersuite, info: info,
                                                   encapsulatedKey: enc)
                }
                return try recipient.open(ciphertext, authenticating: header)
            }
            let header = Data(bytes.prefix(76))
            XCTAssertNoThrow(try open(header), name)
            for bit in 0..<(76 * 8) {
                var flipped = header
                flipped[bit / 8] ^= UInt8(1 << (bit % 8))
                XCTAssertThrowsError(try open(flipped), "\(name) bit \(bit)")
                refused += 1
            }
        }
        XCTAssertEqual(refused, 4 * 608)
    }
}
