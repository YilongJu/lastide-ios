import Crypto
import Foundation

/// The `received` control frame a device sends after it handled an envelope (section 6.9).
public struct ReceivedReport: Hashable, Sendable {
    /// The sender of the envelopes.
    public let from: DeviceID
    /// The device's `lastRecvSeq` for that sender after the envelope.
    public let upTo: UInt64

    /// The control frame as JSON text.
    public var controlFrame: String { ControlFrame.received(from: from, upTo: upTo) }
}

/// What the phone does with one binary frame from the PC (section 5.6).
public enum ReceiveOutcome: Sendable {
    /// Steps 1 to 3 or 5 failed. Drop the frame silently and send nothing.
    case ignored(String)
    /// Step 4 found a replay or a duplicate. Send `received` and stop.
    case duplicate(ReceivedReport)
    /// The message opened and passed every check. Apply it, persist `record`, then send `received`.
    case message(SyncMessage, ReceivedReport)
    /// The message opened and failed step 6 or 7. Seal and send `reply` when it is not nil, persist `record`, then send `received`.
    case unusable(reply: ErrorMessage?, ReceivedReport)
}

/// The phone's sealed channel to one paired PC (section 5).
///
/// After each call that returns an envelope or an outcome, write `record` to `pairings.json`.
/// `seal` raises `lastSentSeq`, and the record must reach the disk before the envelope leaves.
public struct PCSession: Sendable {
    /// The pairing record, with the current `lastSentSeq` and `lastRecvSeq`.
    public private(set) var record: PairingRecord
    private let phoneKey: Curve25519.KeyAgreement.PrivateKey
    private let pcKey: Curve25519.KeyAgreement.PublicKey
    /// Waiting reply keys with the id of the request that carried each, oldest first. They live in memory only.
    /// Each key opens one answer, to its own request, and the session then forgets it (protocol 7.2 and 7.6).
    private var replyKeys: [(requestID: String, key: Curve25519.KeyAgreement.PrivateKey)] = []

    /// Opens a channel from a stored record and the phone key from the Keychain.
    public init(record: PairingRecord, phoneKey: Curve25519.KeyAgreement.PrivateKey) throws {
        self.record = record
        self.phoneKey = phoneKey
        self.pcKey = try record.pcPublicKey()
    }

    /// The number of reply keys waiting for `evidence` or `learning-words`.
    public var waitingReplyKeyCount: Int { replyKeys.count }

    /// Whether the reply key of this request still waits for its answer.
    public func holdsReplyKey(for requestID: String) -> Bool { replyKeys.contains { $0.requestID == requestID } }

    /// Seals one phone message to the PC in Auth mode, with the flags and slot of Table 20 (section 5.7).
    public mutating func seal(_ message: SyncMessage, now: Int) throws -> SealedEnvelope {
        let type = message.type
        precondition(type.kind == .message && type.direction != .pcToPhone, "\(type.rawValue) is not a phone message")
        let plaintext = try message.encoded()
        var counter = SequenceCounter(lastSentSeq: record.lastSentSeq)
        let seq = try counter.next(now: now)
        record.lastSentSeq = seq
        return try sealEnvelope(kind: .message, flags: type.flags, slot: type.slot, sender: record.phoneId, recipient: .pc,
                                seq: seq, recipientKey: pcKey, senderKey: phoneKey,
                                info: Labels.messageInfo(record.pairingId), plaintext: plaintext)
    }

    /// Builds an `evidence-request` with a fresh reply key, kept in memory until its answer opens or `dropReplyKey`.
    public mutating func makeEvidenceRequest(draftID: String, storeVersion: Int, now: Int) -> EvidenceRequest {
        let replyKey = Curve25519.KeyAgreement.PrivateKey()
        let id = makeMessageID()
        replyKeys.append((id, replyKey))
        return EvidenceRequest(id: id, sentAt: now, draftId: draftID, storeVersion: storeVersion,
                               replyKey: Base64URL.encode(replyKey.publicKey.rawRepresentation))
    }

    /// Builds a `learning-words-request` for one row's turn reference, with a fresh reply key kept in memory until its
    /// answer opens or `dropReplyKey` (protocol 7.6).
    public mutating func makeLearningWordsRequest(ref: String, now: Int) -> LearningWordsRequest {
        let replyKey = Curve25519.KeyAgreement.PrivateKey()
        let id = makeMessageID()
        replyKeys.append((id, replyKey))
        return LearningWordsRequest(id: id, sentAt: now, ref: ref, replyKey: Base64URL.encode(replyKey.publicKey.rawRepresentation))
    }

    /// Deletes the reply key of one request. Call it when that request's screen closes.
    public mutating func dropReplyKey(requestID: String) { replyKeys.removeAll { $0.requestID == requestID } }

    /// Deletes every reply key. Call it when the app leaves the active state, the PC goes offline or the socket ends.
    public mutating func dropReplyKeys() { replyKeys.removeAll() }

    /// Records the PC's schema revision from `schema` in a snapshot or `pair-accept` (section 7.1).
    public mutating func notePCSchema(_ schema: Int) {
        precondition(schema >= 1 && schema <= 65_535, "a schema revision lies between 1 and 65535")
        record.pcSchema = schema
    }

    /// Records when the phone last saw the PC: `pcLastSeenAt` of `welcome`, or the phone's clock at a `presence` frame.
    public mutating func notePCLastSeen(at time: Int) {
        precondition(time >= 0 && time <= LastideProtocol.largestInteger, "a time lies between 0 and 2^53 - 1")
        record.pcLastSeenAt = time
    }

    /// Runs the receive checks of section 5.6 on one binary frame from the socket.
    public mutating func receive(_ frame: Data, now: Int) -> ReceiveOutcome {
        let header: EnvelopeHeader
        do { header = try EnvelopeHeader(frame: frame) } catch { return .ignored("bad header: \(error)") }
        guard header.recipient == record.phoneId else { return .ignored("not addressed to this phone") }
        guard header.kind == .message else { return .ignored("kind \(header.kind.rawValue) on the session socket") }
        guard header.sender == .pc else { return .ignored("not from the PC") }
        guard header.seq > record.lastRecvSeq else {
            return .duplicate(ReceivedReport(from: .pc, upTo: record.lastRecvSeq))
        }
        let ciphertext = frame.dropFirst(LastideProtocol.headerSize)
        let aad = header.bytes
        let info = Labels.messageInfo(record.pairingId)
        var plaintext: Data?
        var openedBy: String?
        if header.flags.contains(.replyKey) {
            for entry in replyKeys.reversed() {
                if let opened = try? Self.open(ciphertext, aad: aad, enc: header.enc, key: entry.key, info: info, sender: pcKey) {
                    plaintext = opened
                    openedBy = entry.requestID
                    break
                }
            }
        } else {
            plaintext = try? Self.open(ciphertext, aad: aad, enc: header.enc, key: phoneKey, info: info, sender: pcKey)
        }
        guard let plaintext else { return .ignored("the envelope did not open") }
        // A reply key opens one answer: the PC forgets the key after it seals, so the phone forgets it too.
        if let openedBy { dropReplyKey(requestID: openedBy) }

        record.lastRecvSeq = header.seq
        let report = ReceivedReport(from: .pc, upTo: header.seq)
        let message: SyncMessage
        do {
            message = try SyncMessage.decode(plaintext)
        } catch let failure as MessageDecodingError {
            let reply = failure.type == MessageType.error.rawValue ? nil
                : ErrorMessage(id: makeMessageID(), sentAt: now,
                               inReplyTo: failure.messageID, code: failure.code, detail: String(failure.detail.prefix(200)))
            return .unusable(reply: reply, report)
        } catch {
            preconditionFailure("SyncMessage.decode throws only MessageDecodingError")
        }
        let type = message.type
        guard type.kind == .message, type.direction != .phoneToPC, type.flags == header.flags, type.slot == header.slot else {
            let reply = type == .error ? nil
                : ErrorMessage(id: makeMessageID(), sentAt: now, inReplyTo: message.id,
                               code: .badMessage, detail: "\(type.rawValue) does not fit this kind, direction, flags or slot")
            return .unusable(reply: reply, report)
        }
        // A reply key belongs to one request, so its answer must name that request.
        if let openedBy, message.answeredRequestID != openedBy {
            return .unusable(reply: ErrorMessage(id: makeMessageID(), sentAt: now, inReplyTo: message.id, code: .badMessage,
                                                 detail: "\(type.rawValue) names another request than its reply key"), report)
        }
        return .message(message, report)
    }

    private static func open(_ ciphertext: Data, aad: Data, enc: Data, key: Curve25519.KeyAgreement.PrivateKey, info: Data,
                             sender: Curve25519.KeyAgreement.PublicKey) throws -> Data {
        var recipient = try HPKE.Recipient(privateKey: key, ciphersuite: LastideProtocol.ciphersuite, info: info,
                                           encapsulatedKey: enc, authenticatedBy: sender)
        return try recipient.open(ciphertext, authenticating: aad)
    }
}

extension SyncMessage {
    /// The request id that an answer sealed to a reply key names, or nil for every other type.
    var answeredRequestID: String? {
        switch self {
        case .evidence(let evidence): return evidence.requestId
        case .learningWords(let words): return words.requestId
        default: return nil
        }
    }
}
