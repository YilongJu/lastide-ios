// The protocol's test vectors through Apple's CryptoKit (protocol Table 29, the simulator column).
// The package tests run the same vectors through swift-crypto on Linux. On an Apple platform the
// `Crypto` module re-exports CryptoKit, so this file imports CryptoKit there and `Crypto` elsewhere.
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import LastideKit
import XCTest

private final class BundleToken {}

private enum Vectors {
    static func object(_ name: String) throws -> Any {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle(for: BundleToken.self)
        #endif
        let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "json", subdirectory: "Vectors"),
                                "the test bundle lacks Vectors/\(name).json")
        return try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    }
}

private func hex(_ value: Any?) throws -> Data {
    let text = try XCTUnwrap(value as? String, "a hex field is missing")
    XCTAssertEqual(text.count % 2, 0, "odd hex length")
    var bytes = Data(capacity: text.count / 2)
    var index = text.startIndex
    while index < text.endIndex {
        let next = text.index(index, offsetBy: 2)
        bytes.append(try XCTUnwrap(UInt8(text[index..<next], radix: 16), "not hex: \(text[index..<next])"))
        index = next
    }
    return bytes
}

private let suite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly
private let headerSize = 76

final class RFC9180CryptoKitTests: XCTestCase {
    /// RFC 9180 appendix A.2.1 (Base) and A.2.3 (Auth): open all 257 encryptions in order and match all 3 exports.
    func testBaseAndAuthEntriesOpenEveryEncryptionAndMatchEveryExport() throws {
        let entries = try XCTUnwrap(Vectors.object("rfc9180-a2") as? [[String: Any]])
        XCTAssertEqual(entries.map { $0["mode"] as? Int }, [0, 2])
        var opened = 0
        var exported = 0
        for entry in entries {
            XCTAssertEqual(entry["kem_id"] as? Int, 32)
            XCTAssertEqual(entry["kdf_id"] as? Int, 1)
            XCTAssertEqual(entry["aead_id"] as? Int, 3)
            let skR = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: hex(entry["skRm"]))
            XCTAssertEqual(skR.publicKey.rawRepresentation, try hex(entry["pkRm"]))
            let info = try hex(entry["info"])
            let enc = try hex(entry["enc"])
            var recipient: HPKE.Recipient
            if try XCTUnwrap(entry["mode"] as? Int) == 2 {
                let pkS = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: hex(entry["pkSm"]))
                recipient = try HPKE.Recipient(privateKey: skR, ciphersuite: suite, info: info, encapsulatedKey: enc,
                                               authenticatedBy: pkS)
            } else {
                recipient = try HPKE.Recipient(privateKey: skR, ciphersuite: suite, info: info, encapsulatedKey: enc)
            }
            let encryptions = try XCTUnwrap(entry["encryptions"] as? [[String: Any]])
            XCTAssertEqual(encryptions.count, 257)
            for item in encryptions {
                XCTAssertEqual(try recipient.open(hex(item["ct"]), authenticating: hex(item["aad"])), try hex(item["pt"]))
                opened += 1
            }
            let exports = try XCTUnwrap(entry["exports"] as? [[String: Any]])
            XCTAssertEqual(exports.count, 3)
            for item in exports {
                let length = try XCTUnwrap(item["L"] as? Int)
                let value = try recipient.exportSecret(context: hex(item["exporter_context"]), outputByteCount: length)
                XCTAssertEqual(value.withUnsafeBytes { Data($0) }, try hex(item["exported_value"]))
                exported += 1
            }
        }
        XCTAssertEqual(opened, 514)
        XCTAssertEqual(exported, 6)
    }
}

final class LastideVectorCryptoKitTests: XCTestCase {
    private var vector: [String: Any] = [:]
    private var pcKey: Curve25519.KeyAgreement.PrivateKey!
    private var phoneKey: Curve25519.KeyAgreement.PrivateKey!

    override func setUpWithError() throws {
        vector = try XCTUnwrap(Vectors.object("lastide-v1") as? [String: Any])
        let keys = try XCTUnwrap(vector["keys"] as? [String: Any])
        pcKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: hex(keys["pcPrivateKey"]))
        phoneKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: hex(keys["phonePrivateKey"]))
        XCTAssertEqual(pcKey.publicKey.rawRepresentation, try hex(keys["pcPublicKey"]))
        XCTAssertEqual(phoneKey.publicKey.rawRepresentation, try hex(keys["phonePublicKey"]))
    }

    private func envelope(_ name: String) throws -> [String: Any] { try XCTUnwrap(vector[name] as? [String: Any]) }

    /// Opens one envelope of the vector as its recipient. `authenticated` is false only for the Base-mode pair request.
    private func open(_ bytes: Data, info: Data, as recipientKey: Curve25519.KeyAgreement.PrivateKey,
                      from senderKey: Curve25519.KeyAgreement.PublicKey?) throws -> (HPKE.Recipient, Data) {
        XCTAssertGreaterThanOrEqual(bytes.count, headerSize + 16)
        let header = bytes.prefix(headerSize)
        let enc = header.suffix(32)
        var recipient: HPKE.Recipient
        if let senderKey {
            recipient = try HPKE.Recipient(privateKey: recipientKey, ciphersuite: suite, info: info, encapsulatedKey: enc,
                                           authenticatedBy: senderKey)
        } else {
            recipient = try HPKE.Recipient(privateKey: recipientKey, ciphersuite: suite, info: info, encapsulatedKey: enc)
        }
        let plaintext = try recipient.open(bytes.dropFirst(headerSize), authenticating: header)
        return (recipient, plaintext)
    }

    private func plaintext(_ entry: [String: Any]) throws -> Data {
        Data(try XCTUnwrap(entry["plaintext"] as? String).utf8)
    }

    func testPairRequestOpensWithThePCKey() throws {
        let entry = try envelope("pairRequest")
        let bytes = try hex(entry["envelope"])
        XCTAssertEqual(bytes.prefix(headerSize), try hex(entry["aad"]))
        XCTAssertEqual(Data(SHA256.hash(data: bytes)), try hex(entry["envelopeSha256"]))
        let (_, opened) = try open(bytes, info: hex(entry["info"]), as: pcKey, from: nil)
        XCTAssertEqual(opened, try plaintext(entry))
        guard case .pairRequest = try SyncMessage.decode(opened) else { return XCTFail("not a pair-request") }
    }

    func testPairReceivedOpensInAuthModeAndGivesTheCheckCode() throws {
        let entry = try envelope("pairReceived")
        let (recipient, opened) = try open(hex(entry["envelope"]), info: hex(entry["info"]), as: phoneKey,
                                           from: pcKey.publicKey)
        XCTAssertEqual(opened, try plaintext(entry))
        let e = try recipient.exportSecret(context: hex(entry["exporterContext"]), outputByteCount: 8)
        let bytes = e.withUnsafeBytes { Data($0) }
        XCTAssertEqual(bytes, try hex(entry["exportedValue"]))
        XCTAssertEqual(bytes, try hex("9c110ed03f0e1a16"))
        let n = bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let code = String(n % 1_000_000)
        let padded = String(repeating: "0", count: 6 - code.count) + code
        XCTAssertEqual(padded, entry["checkCode"] as? String)
        XCTAssertEqual(padded, "714390")
    }

    func testPairAcceptOpensInAuthMode() throws {
        let entry = try envelope("pairAccept")
        let (_, opened) = try open(hex(entry["envelope"]), info: hex(entry["info"]), as: phoneKey, from: pcKey.publicKey)
        XCTAssertEqual(opened, try plaintext(entry))
        guard case .pairAccept(let accept) = try SyncMessage.decode(opened) else { return XCTFail("not a pair-accept") }
        XCTAssertEqual(accept.pcName, "My PC")
    }

    func testQueueMessageOpensAndValidates() throws {
        let entry = try envelope("message")
        let (_, opened) = try open(hex(entry["envelope"]), info: hex(entry["info"]), as: phoneKey, from: pcKey.publicKey)
        XCTAssertEqual(opened, try plaintext(entry))
        let message = try SyncMessage.decode(opened)
        try message.validate()
        guard case .queue(let queue) = message else { return XCTFail("not a queue") }
        XCTAssertEqual(queue.storeVersion, 42)
        XCTAssertEqual(queue.drafts.map(\.text), ["Use sentence case in headings."])
    }

    /// Each single-bit flip of each header refuses to open: 608 flips on each of the 4 envelopes.
    func testEveryHeaderBitFlipRefuses() throws {
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
            for bit in 0..<(headerSize * 8) {
                var flipped = bytes
                flipped[bit / 8] ^= UInt8(1 << (bit % 8))
                XCTAssertThrowsError(try open(flipped, info: info, as: key, from: sender), "\(name) bit \(bit)")
                refused += 1
            }
        }
        XCTAssertEqual(refused, 2_432)
    }

    /// A message CryptoKit seals as the phone opens with the PC key, so the app's sender side matches the spec.
    func testAuthModeRoundTripWithTheVectorKeys() throws {
        let info = try hex(envelope("message")["info"])
        var sender = try HPKE.Sender(recipientKey: pcKey.publicKey, ciphersuite: suite, info: info, authenticatedBy: phoneKey)
        let aad = Data(repeating: 7, count: headerSize)
        let sealed = try sender.seal(Data("{}".utf8), authenticating: aad)
        var recipient = try HPKE.Recipient(privateKey: pcKey, ciphersuite: suite, info: info,
                                           encapsulatedKey: sender.encapsulatedKey, authenticatedBy: phoneKey.publicKey)
        XCTAssertEqual(try recipient.open(sealed, authenticating: aad), Data("{}".utf8))
    }
}
