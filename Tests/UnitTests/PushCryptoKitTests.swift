// The push vector of protocol section 10.5 through Apple's CryptoKit (design Table 21, check U1).
// The package tests run the same vector through swift-crypto on Linux.
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import LastideKit
import XCTest

private final class PushBundleToken {}

final class PushCryptoKitTests: XCTestCase {
    private var vector: [String: Any] = [:]
    private var record: PairingRecord!
    private var phoneKey: Curve25519.KeyAgreement.PrivateKey!

    override func setUpWithError() throws {
        let url = try XCTUnwrap(Bundle(for: PushBundleToken.self).url(forResource: "lastide-push-v1", withExtension: "json",
                                                                       subdirectory: "Vectors"),
                                "the test bundle lacks Vectors/lastide-push-v1.json")
        vector = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let keys = try XCTUnwrap(vector["keys"] as? [String: Any])
        let ids = try XCTUnwrap(vector["ids"] as? [String: Any])
        phoneKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Self.hex(keys["phonePrivateKey"]))
        let json: [String: Any] = [
            "pairingId": Base64URL.encode(try Self.hex(ids["pairingId"])),
            "relayOrigin": "https://relay.example",
            "pcKey": Base64URL.encode(try Self.hex(keys["pcPublicKey"])),
            "pcName": "My PC",
            "pcSchema": 3,
            "phoneId": Base64URL.encode(try Self.hex(ids["phoneId"])),
            "pairedAt": 1_794_992_400_000,
            "lastSentSeq": 1,
            "lastRecvSeq": 1,
            "features": ["mailbox", "push"],
        ]
        record = try JSONDecoder().decode(PairingRecord.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private static func hex(_ value: Any?) throws -> Data {
        let text = try XCTUnwrap(value as? String, "a hex field is missing")
        var bytes = Data(capacity: text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            bytes.append(try XCTUnwrap(UInt8(text[index..<next], radix: 16), "not hex"))
            index = next
        }
        return bytes
    }

    private func entry(_ name: String) throws -> [String: Any] { try XCTUnwrap(vector[name] as? [String: Any]) }

    /// The phone's opener, built on CryptoKit here, opens the notice and the count update of the vector.
    func testU1TheOpenerOpensThePushVectorOnCryptoKit() throws {
        let key = phoneKey.rawRepresentation
        let notice = try entry("notice")
        let payload: [AnyHashable: Any] = ["lastide": ["v": 1, "e": try XCTUnwrap(notice["e"] as? String)]]
        let opened = try PushOpener.open(PushOpener.envelope(from: payload), slot: PushOpener.noticeSlot, records: [record],
                                         phoneKey: { _ in key })
        XCTAssertEqual(opened.notice?.draft?.text, "Name each branch after its ticket.")
        XCTAssertEqual(opened.notice?.storeVersion, 43)
        XCTAssertEqual(opened.seq, 1_794_992_520_000)
        let countUpdate = try entry("countUpdate")
        let countPayload: [AnyHashable: Any] = ["lastide": ["v": 1, "e": try XCTUnwrap(countUpdate["e"] as? String)]]
        let counted = try PushOpener.open(PushOpener.envelope(from: countPayload), slot: PushOpener.countUpdateSlot,
                                          records: [record], phoneKey: { _ in key })
        XCTAssertEqual(counted.countUpdate?.storeVersion, 44)
        XCTAssertEqual(counted.countUpdate?.queueCount, 0)
    }

    /// The raw CryptoKit open of the notice gives the vector's plaintext, so the opener's info and AAD match the PC's.
    func testU1CryptoKitOpensTheNoticeWithINFOPUSH() throws {
        let notice = try entry("notice")
        let bytes = try Self.hex(notice["envelope"])
        var recipient = try HPKE.Recipient(privateKey: phoneKey, ciphersuite: .Curve25519_SHA256_ChachaPoly,
                                           info: Self.hex(notice["info"]), encapsulatedKey: bytes.subdata(in: 44..<76),
                                           authenticatedBy: try record.pcPublicKey())
        let plaintext = try recipient.open(bytes.dropFirst(76), authenticating: bytes.prefix(76))
        XCTAssertEqual(String(decoding: plaintext, as: UTF8.self), notice["plaintext"] as? String)
        XCTAssertEqual(try Self.hex(notice["info"]), Data("lastide/v1/push".utf8) + Data([0]) + record.pairingId.bytes)
    }
}
