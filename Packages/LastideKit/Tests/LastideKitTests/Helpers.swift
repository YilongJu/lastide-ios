import Crypto
import Foundation
@testable import LastideKit
import XCTest

enum Vectors {
    static func data(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Vectors"))
        return try Data(contentsOf: url)
    }

    static func object(_ name: String) throws -> Any { try JSONSerialization.jsonObject(with: data(name)) }
}

func hex(_ value: Any?) throws -> Data { try Data(hex: XCTUnwrap(value as? String)) }

let relayOrigin = "https://relay.example"

/// A PC built from Swift's HPKE, for round trips with the phone's code.
struct FakePC {
    let key = Curve25519.KeyAgreement.PrivateKey()
    let pairingID = try! PairingID(bytes: SecureRandom.bytes(16))
    let ticket = try! PairingTicket(bytes: SecureRandom.bytes(16))
    var counter = SequenceCounter(lastSentSeq: 0)
    var now = 1_794_992_400_000

    var qr: String {
        "lastide-pair:1?k=\(Base64URL.encode(key.publicKey.rawRepresentation))&p=\(pairingID.base64url)&t=\(ticket.base64url)&r=https%3A%2F%2Frelay.example"
    }

    mutating func nextSeq() -> UInt64 {
        now += 1_000
        return try! counter.next(now: now)
    }

    /// Opens a phone's pair request in Base mode.
    func openPairRequest(_ envelope: Data) throws -> (EnvelopeHeader, Data) {
        let header = try EnvelopeHeader(frame: envelope)
        var recipient = try HPKE.Recipient(privateKey: key, ciphersuite: LastideProtocol.ciphersuite,
                                           info: Labels.pairRequestInfo(pairingID), encapsulatedKey: header.enc)
        return (header, try recipient.open(envelope.dropFirst(76), authenticating: header.bytes))
    }

    /// Seals a JSON plaintext as the PC, in Auth mode.
    mutating func seal(_ json: String, kind: EnvelopeKind = .message, flags: EnvelopeFlags = [], slot: UInt8 = 0,
                       to phone: DeviceID, recipientKey: Curve25519.KeyAgreement.PublicKey, info: Data,
                       senderKey: Curve25519.KeyAgreement.PrivateKey? = nil, sender: DeviceID = .pc) throws -> Data {
        try sealEnvelope(kind: kind, flags: flags, slot: slot, sender: sender, recipient: phone, seq: nextSeq(),
                         recipientKey: recipientKey, senderKey: senderKey ?? key, info: info, plaintext: Data(json.utf8)).bytes
    }

    /// Opens a phone's message in Auth mode.
    func openMessage(_ envelope: Data, from phoneKey: Curve25519.KeyAgreement.PublicKey) throws -> (EnvelopeHeader, Data) {
        let header = try EnvelopeHeader(frame: envelope)
        var recipient = try HPKE.Recipient(privateKey: key, ciphersuite: LastideProtocol.ciphersuite,
                                           info: Labels.messageInfo(pairingID), encapsulatedKey: header.enc,
                                           authenticatedBy: phoneKey)
        return (header, try recipient.open(envelope.dropFirst(76), authenticating: header.bytes))
    }
}

/// A paired phone and PC with a live session.
struct PairedFixture {
    var pc = FakePC()
    let phoneKey = Curve25519.KeyAgreement.PrivateKey()
    let phoneID = DeviceID.random()
    var session: PCSession

    init() {
        let pc = FakePC()
        self.pc = pc
        let record = PairingRecord(pairingId: pc.pairingID, relayOrigin: relayOrigin,
                                   pcKey: Base64URL.encode(pc.key.publicKey.rawRepresentation), pcName: "My PC", pcSchema: 1,
                                   phoneId: phoneID, pairedAt: 1_794_992_400_000, pcLastSeenAt: nil,
                                   lastSentSeq: 1_794_992_400_000, lastRecvSeq: 1_794_992_400_000, features: [.mailbox])
        session = try! PCSession(record: record, phoneKey: phoneKey)
    }

    mutating func fromPC(_ json: String, flags: EnvelopeFlags = [], slot: UInt8 = 0,
                         recipientKey: Curve25519.KeyAgreement.PublicKey? = nil) throws -> Data {
        try pc.seal(json, flags: flags, slot: slot, to: phoneID, recipientKey: recipientKey ?? phoneKey.publicKey,
                    info: Labels.messageInfo(pc.pairingID))
    }
}

let sampleID = "GPEkxfZwlv5u32ui7BBUtw"
let sampleTime = 1_794_992_400_000

func queueJSON(storeVersion: Int, drafts: [String] = [draftJSON()], omitted: Int = 0, id: String = sampleID) -> String {
    #"{"type":"queue","id":"\#(id)","sentAt":\#(sampleTime),"schema":1,"storeVersion":\#(storeVersion),"omitted":\#(omitted),"drafts":[\#(drafts.joined(separator: ","))]}"#
}

func draftJSON(id: String = "d-0001", version: Int = 41, kind: String = "new", text: String = "Use sentence case in headings.",
               desktopOnly: Bool = false) -> String {
    #"{"id":"\#(id)","changedAtStoreVersion":\#(version),"draftKind":"\#(kind)","text":"\#(text)","scope":{"scope":"everyProject","kindOfWork":null,"projectNames":[]},"scopeOptions":[{"id":"s1","scope":"thisProject","kindOfWork":null,"projectNames":["northwind-reports"]},{"id":"s3","scope":"everyProject","kindOfWork":null,"projectNames":[]}],"group":"writing","strength":"preference","agents":["claudeCode","codex"],"desktopOnly":\#(desktopOnly),"evidence":[{"id":"1","at":1794319200000,"projectName":"northwind-reports","agent":"claudeCode","signal":"typedTurn"}],"evidenceCount":3,"sessionCount":3,"projectCount":2,"leftOutCount":0,"relatedRuleIds":[],"createdAt":1794990600000}"#
}

func ruleJSON(id: String = "r-0007", version: Int = 30, source: String = "learned", state: String = "on",
              desktopOnly: Bool = false) -> String {
    #"{"id":"\#(id)","changedAtStoreVersion":\#(version),"text":"Write each date as year, month, day.","scope":{"scope":"everyProject","kindOfWork":null,"projectNames":[]},"scopeOptions":[{"id":"s1","scope":"everyProject","kindOfWork":null,"projectNames":[]}],"group":"writing","strength":"preference","agents":["claudeCode","codex"],"source":"\#(source)","state":"\#(state)","approvedAt":1794992400000,"editedAt":null,"editedOn":null,"correctionsBeforeApproval":4,"violationsSinceApproval":1,"violationsLast30Days":1,"lastSeenAt":1794992400000,"folderGone":false,"desktopOnly":\#(desktopOnly)}"#
}

func libraryJSON(storeVersion: Int, rules: [String] = [ruleJSON()]) -> String {
    #"{"type":"library","id":"\#(sampleID)","sentAt":\#(sampleTime),"schema":1,"storeVersion":\#(storeVersion),"omitted":0,"rules":[\#(rules.joined(separator: ","))]}"#
}

func acknowledgementJSON(decisionId: String, result: String, reason: String?, storeVersion: Int, current: String = "null") -> String {
    let appliedAt = result == "applied" ? String(sampleTime) : "null"
    let reasonText = reason.map { "\"\($0)\"" } ?? "null"
    return #"{"type":"acknowledgement","id":"\#(makeMessageID())","sentAt":\#(sampleTime),"decisionId":"\#(decisionId)","result":"\#(result)","appliedAt":\#(appliedAt),"reason":\#(reasonText),"storeVersion":\#(storeVersion),"current":\#(current)}"#
}

func decode(_ json: String) throws -> SyncMessage { try SyncMessage.decode(Data(json.utf8)) }
