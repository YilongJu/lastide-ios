import Crypto
import Foundation

/// The phone's record of one PC, as `pairings.json` holds it (Table 8).
public struct PairingRecord: Hashable, Sendable, Codable {
    public var pairingId: PairingID
    public var relayOrigin: String
    /// The PC's public key, base64url.
    public var pcKey: String
    public var pcName: String
    public var pcSchema: Int
    public var phoneId: DeviceID
    public var pairedAt: Int
    public var pcLastSeenAt: Int?
    /// The phone's send counter for this pairing. Write the record before sending each envelope.
    public var lastSentSeq: UInt64
    /// The highest `seq` accepted from the PC.
    public var lastRecvSeq: UInt64
    public var features: [Feature]
    /// The App Attest key id of this pairing, or nil when the phone did not attest (design section 7.1).
    /// A record written before phase 7 lacks the field.
    public var attestKeyId: String?

    /// The PC key as a key value.
    public func pcPublicKey() throws -> Curve25519.KeyAgreement.PublicKey {
        try Curve25519.KeyAgreement.PublicKey(rawRepresentation: Base64URL.decode(pcKey, byteCount: 32))
    }

    /// The socket URL of the PC's room.
    public var socketURL: URL {
        URL(string: "wss://" + relayOrigin.dropFirst("https://".count) + "/api/relay/" + pairingId.base64url)!
    }
}

/// Why the phone dropped a frame during pairing. The phone keeps waiting after any of these.
public enum PairingError: Error, Equatable, Sendable {
    /// The frame is not a kind 2 envelope for this phone from the PC, or it came out of order.
    case unexpectedFrame(String)
    /// The HPKE open threw.
    case openFailed
    /// The plaintext does not decode or does not fit its slot.
    case badMessage(String)
    /// `pairingId` or `phoneId` differs from this pairing.
    case wrongPairing
}

/// What one pair reply changed.
public enum PairingEvent: Sendable {
    /// `pair-received` opened. Show "Type this code on your PC" and the code.
    case checkCode(CheckCode)
    /// `pair-accept` opened. Store the record and the two Keychain items, then connect as `phone`.
    case accepted(PairingResult)
    /// `pair-refuse` opened. Show `reason.displayText`. The ticket is dead.
    case refused(PairRefuseReason)
}

/// A finished pairing: the record and the two secrets for the Keychain.
public struct PairingResult: Sendable {
    /// The record for `pairings.json`.
    public let record: PairingRecord
    /// The phone's private key, stored as the Keychain item `<pairing id>.key`.
    public let phoneKey: Curve25519.KeyAgreement.PrivateKey
    /// The 32-byte phone token, stored as the Keychain item `<pairing id>.token`.
    public let phoneToken: Data
}

/// The phone's side of one pairing, from the pair request to `pair-accept` or `pair-refuse` (section 4.3).
public struct PhonePairing: Sendable {
    /// The scanned QR code.
    public let payload: QRPayload
    /// The phone's new device id for this pairing.
    public let phoneID: DeviceID
    /// The phone's new key pair for this pairing.
    public let phoneKey: Curve25519.KeyAgreement.PrivateKey
    /// The pair request envelope, sent as the pairing socket's one binary frame.
    public let pairRequestEnvelope: Data
    /// SHA-256 of the pair request envelope.
    public let h1: Data
    /// The `seq` of the pair request, the phone's first `lastSentSeq`.
    public let pairRequestSeq: UInt64
    private var pairReceivedSeq: UInt64?
    private var finished = false

    /// Makes a phone key and a device id and seals the pair request to the PC key in Base mode.
    public init(payload: QRPayload, deviceName: String, model: String, app: AppInfo, consentAcceptedAt: Int, now: Int) throws {
        let phoneKey = Curve25519.KeyAgreement.PrivateKey()
        let phoneID = DeviceID.random()
        var counter = SequenceCounter(lastSentSeq: 0)
        let seq = try counter.next(now: now)
        let request = PairRequest(id: makeMessageID(), sentAt: now, ticket: payload.ticket.base64url,
                                  phoneId: phoneID.base64url, phoneKey: Base64URL.encode(phoneKey.publicKey.rawRepresentation),
                                  deviceName: deviceName, model: model, app: app,
                                  schema: LastideProtocol.schemaRevision, consent: Consent(acceptedAt: consentAcceptedAt))
        let sealed = try sealEnvelope(kind: .pairRequest, flags: [], slot: 0, sender: phoneID, recipient: .pc, seq: seq,
                                      recipientKey: payload.pcKey, senderKey: nil,
                                      info: Labels.pairRequestInfo(payload.pairingID),
                                      plaintext: SyncMessage.pairRequest(request).encoded())
        self.init(payload: payload, phoneKey: phoneKey, phoneID: phoneID, pairRequestEnvelope: sealed.bytes, pairRequestSeq: seq)
    }

    /// Resumes from a pair request that was already sealed. The tests use it with the Lastide vector.
    init(payload: QRPayload, phoneKey: Curve25519.KeyAgreement.PrivateKey, phoneID: DeviceID, pairRequestEnvelope: Data,
         pairRequestSeq: UInt64) {
        self.payload = payload
        self.phoneKey = phoneKey
        self.phoneID = phoneID
        self.pairRequestEnvelope = pairRequestEnvelope
        self.pairRequestSeq = pairRequestSeq
        self.h1 = Data(SHA256.hash(data: pairRequestEnvelope))
    }

    /// Opens one kind 2 frame from the pairing socket. Throws `PairingError` for a frame the phone drops.
    public mutating func receive(_ frame: Data, now: Int) throws -> PairingEvent {
        guard !finished else { throw PairingError.unexpectedFrame("the pairing already ended") }
        let header: EnvelopeHeader
        do { header = try EnvelopeHeader(frame: frame) } catch { throw PairingError.unexpectedFrame("bad header") }
        guard header.kind == .pairReply, header.flags.isEmpty, header.slot <= 1 else {
            throw PairingError.unexpectedFrame("not a pair reply")
        }
        guard header.sender == .pc, header.recipient == phoneID else { throw PairingError.unexpectedFrame("wrong device ids") }
        if header.slot == 1 {
            guard pairReceivedSeq == nil else { throw PairingError.unexpectedFrame("a second pair-received") }
        } else if let pairReceivedSeq, header.seq <= pairReceivedSeq {
            throw PairingError.unexpectedFrame("seq not above pair-received")
        }
        var recipient: HPKE.Recipient
        let plaintext: Data
        do {
            recipient = try HPKE.Recipient(privateKey: phoneKey, ciphersuite: LastideProtocol.ciphersuite,
                                           info: Labels.pairReplyInfo(h1: h1), encapsulatedKey: header.enc,
                                           authenticatedBy: payload.pcKey)
            plaintext = try recipient.open(frame.dropFirst(LastideProtocol.headerSize), authenticating: header.bytes)
        } catch {
            throw PairingError.openFailed
        }
        let message: SyncMessage
        do { message = try SyncMessage.decode(plaintext) } catch { throw PairingError.badMessage("\(error)") }
        switch (header.slot, message) {
        case (1, .pairReceived(let received)):
            guard received.pairingId == payload.pairingID.base64url, received.phoneId == phoneID.base64url else {
                throw PairingError.wrongPairing
            }
            let exported = try recipient.exportSecret(context: Labels.checkCodeContext(h1: h1), outputByteCount: 8)
            pairReceivedSeq = header.seq
            return .checkCode(CheckCode(exported: exported.withUnsafeBytes { Data($0) }))
        case (0, .pairAccept(let accept)):
            guard accept.pairingId == payload.pairingID.base64url, accept.phoneId == phoneID.base64url else {
                throw PairingError.wrongPairing
            }
            guard pairReceivedSeq != nil else { throw PairingError.unexpectedFrame("pair-accept before pair-received") }
            finished = true
            let record = PairingRecord(pairingId: payload.pairingID, relayOrigin: payload.relayOrigin,
                                       pcKey: Base64URL.encode(payload.pcKey.rawRepresentation), pcName: accept.pcName,
                                       pcSchema: accept.schema, phoneId: phoneID, pairedAt: now, pcLastSeenAt: nil,
                                       lastSentSeq: pairRequestSeq, lastRecvSeq: header.seq, features: accept.features)
            return .accepted(PairingResult(record: record, phoneKey: phoneKey,
                                           phoneToken: try Base64URL.decode(accept.phoneToken, byteCount: 32)))
        case (0, .pairRefuse(let refuse)):
            guard refuse.pairingId == payload.pairingID.base64url, refuse.phoneId == phoneID.base64url else {
                throw PairingError.wrongPairing
            }
            finished = true
            return .refused(refuse.reason)
        default:
            throw PairingError.badMessage("\(message.type.rawValue) does not fit slot \(header.slot)")
        }
    }
}
