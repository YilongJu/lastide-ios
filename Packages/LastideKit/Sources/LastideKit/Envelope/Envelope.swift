import Crypto
import Foundation

/// Byte 1 of the envelope (Table 11).
public enum EnvelopeKind: UInt8, Sendable, CaseIterable {
    case pairRequest = 1
    case pairReply = 2
    case message = 3
    case push = 4
}

/// Byte 2 of the envelope. Bits 2 to 7 stay clear in version 1.
public struct EnvelopeFlags: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    /// The relay may keep the envelope for 7 days while the recipient is offline.
    public static let mailbox = EnvelopeFlags(rawValue: 0x01)
    /// The envelope is sealed to a one-time reply key.
    public static let replyKey = EnvelopeFlags(rawValue: 0x02)
    static let defined: EnvelopeFlags = [.mailbox, .replyKey]
}

/// Why an envelope header was refused.
public enum EnvelopeError: Error, Equatable, Sendable {
    case badSize(Int)
    case badVersion(UInt8)
    case badKind(UInt8)
    case badFlags(UInt8)
    case badSlot(UInt8)
    case badSeq(UInt64)
    case badEncapsulatedKey
}

/// The 76-byte clear header that is the AEAD's associated data (Table 10).
public struct EnvelopeHeader: Hashable, Sendable {
    /// The envelope kind.
    public let kind: EnvelopeKind
    /// The MAILBOX and REPLY_KEY bits.
    public let flags: EnvelopeFlags
    /// The mailbox slot, or 1 for `pair-received`.
    public let slot: UInt8
    /// The sender's device id.
    public let sender: DeviceID
    /// The recipient's device id.
    public let recipient: DeviceID
    /// The sender's sequence number.
    public let seq: UInt64
    /// The 32-byte HPKE encapsulated key.
    public let enc: Data

    /// Builds a header and checks every field rule of Table 10.
    public init(kind: EnvelopeKind, flags: EnvelopeFlags, slot: UInt8, sender: DeviceID, recipient: DeviceID,
                seq: UInt64, enc: Data) throws {
        guard flags.isSubset(of: .defined) else { throw EnvelopeError.badFlags(flags.rawValue) }
        guard slot <= 2 else { throw EnvelopeError.badSlot(slot) }
        guard seq >= 1, seq < LastideProtocol.seqLimit else { throw EnvelopeError.badSeq(seq) }
        guard enc.count == 32 else { throw EnvelopeError.badEncapsulatedKey }
        self.kind = kind
        self.flags = flags
        self.slot = slot
        self.sender = sender
        self.recipient = recipient
        self.seq = seq
        self.enc = Data(enc)
    }

    /// Reads the header of a whole frame and checks steps 1 and 2 of section 5.6.
    public init(frame: Data) throws {
        let bytes = [UInt8](frame)
        guard bytes.count >= LastideProtocol.smallestEnvelope, bytes.count <= LastideProtocol.largestEnvelope else {
            throw EnvelopeError.badSize(bytes.count)
        }
        guard bytes[0] == LastideProtocol.version else { throw EnvelopeError.badVersion(bytes[0]) }
        guard let kind = EnvelopeKind(rawValue: bytes[1]) else { throw EnvelopeError.badKind(bytes[1]) }
        var seq: UInt64 = 0
        for byte in bytes[36..<44] { seq = seq << 8 | UInt64(byte) }
        try self.init(kind: kind, flags: EnvelopeFlags(rawValue: bytes[2]), slot: bytes[3],
                      sender: DeviceID(bytes: Data(bytes[4..<20])), recipient: DeviceID(bytes: Data(bytes[20..<36])),
                      seq: seq, enc: Data(bytes[44..<76]))
    }

    /// The 76 header bytes.
    public var bytes: Data {
        var data = Data([LastideProtocol.version, kind.rawValue, flags.rawValue, slot])
        data.append(sender.bytes)
        data.append(recipient.bytes)
        for shift in stride(from: 56, through: 0, by: -8) { data.append(UInt8(truncatingIfNeeded: seq >> UInt64(shift))) }
        data.append(enc)
        return data
    }
}

/// The relay's header checks 1 to 6 of section 6.5. Returns the close code of the first failure, or nil.
func relayHeaderCheck(_ frame: Data) -> Int? {
    let bytes = [UInt8](frame)
    if bytes.count < LastideProtocol.smallestEnvelope { return 4400 }
    if bytes.count > LastideProtocol.largestEnvelope { return 4413 }
    if bytes[0] != 1 { return 4400 }
    if !(1...4).contains(bytes[1]) { return 4400 }
    if bytes[2] & 0xFC != 0 { return 4400 }
    var seq: UInt64 = 0
    for byte in bytes[36..<44] { seq = seq << 8 | UInt64(byte) }
    if seq < 1 || seq >= LastideProtocol.seqLimit { return 4400 }
    let flags = bytes[2], slot = bytes[3]
    switch bytes[1] {
    case 1, 4: if flags != 0 || slot != 0 { return 4400 }
    case 2: if flags != 0 || slot > 1 { return 4400 }
    default:
        if flags & 0x01 != 0 {
            if flags & 0x02 != 0 || slot > 2 { return 4400 }
        } else if slot != 0 {
            return 4400
        }
    }
    return nil
}

/// The HPKE info strings and the exporter context of Table 6.
enum Labels {
    static func pairRequestInfo(_ pairingID: PairingID) -> Data { label("lastide/v1/pair-request", pairingID.bytes) }
    static func pairReplyInfo(h1: Data) -> Data { label("lastide/v1/pair-reply", h1) }
    static func messageInfo(_ pairingID: PairingID) -> Data { label("lastide/v1/message", pairingID.bytes) }
    static func pushInfo(_ pairingID: PairingID) -> Data { label("lastide/v1/push", pairingID.bytes) }
    static func checkCodeContext(h1: Data) -> Data { label("lastide/v1/check-code", h1) }

    private static func label(_ text: String, _ value: Data) -> Data {
        var data = Data(text.utf8)
        data.append(0)
        data.append(value)
        return data
    }
}

/// The 6-digit check code both devices derive from the `pair-received` context (section 4.5).
public struct CheckCode: Hashable, Sendable {
    /// Six ASCII digits with leading zeros, for example "714390".
    public let digits: String

    init(exported: Data) {
        precondition(exported.count == 8, "the check code needs 8 exported bytes")
        var n: UInt64 = 0
        for byte in exported { n = n << 8 | UInt64(byte) }
        let value = String(n % 1_000_000)
        digits = String(repeating: "0", count: 6 - value.count) + value
    }

    /// Two groups of three digits, as the phone shows them: "714 390".
    public var display: String { "\(digits.prefix(3)) \(digits.suffix(3))" }
}

/// One device's send counter: `seq = max(lastSentSeq + 1, now)` (section 5.4).
public struct SequenceCounter: Hashable, Sendable, Codable {
    /// The last `seq` this device sent. Write it to disk before sending the envelope.
    public private(set) var lastSentSeq: UInt64

    /// Starts from a stored `lastSentSeq`, or 0 before the first send.
    public init(lastSentSeq: UInt64) { self.lastSentSeq = lastSentSeq }

    /// Takes the next `seq` and records it. Refuses to reach 2^53.
    public mutating func next(now: Int) throws -> UInt64 {
        precondition(now >= 0, "the clock reads before 1970")
        let candidate = max(lastSentSeq + 1, UInt64(now))
        guard candidate < LastideProtocol.seqLimit else { throw EnvelopeError.badSeq(candidate) }
        lastSentSeq = candidate
        return candidate
    }
}

/// One sealed envelope ready to send as a binary frame.
public struct SealedEnvelope: Hashable, Sendable {
    /// Header and ciphertext.
    public let bytes: Data
    /// The `seq` in its header, which `stored` and `dropped` frames quote.
    public let seq: UInt64
}

/// Seals one plaintext in its own HPKE context and builds the envelope.
func sealEnvelope(kind: EnvelopeKind, flags: EnvelopeFlags, slot: UInt8, sender: DeviceID, recipient: DeviceID,
                  seq: UInt64, recipientKey: Curve25519.KeyAgreement.PublicKey,
                  senderKey: Curve25519.KeyAgreement.PrivateKey?, info: Data, plaintext: Data) throws -> SealedEnvelope {
    precondition(plaintext.count <= LastideProtocol.largestPlaintext, "the plaintext is larger than an envelope holds")
    var context: HPKE.Sender
    if let senderKey {
        context = try HPKE.Sender(recipientKey: recipientKey, ciphersuite: LastideProtocol.ciphersuite, info: info,
                                  authenticatedBy: senderKey)
    } else {
        context = try HPKE.Sender(recipientKey: recipientKey, ciphersuite: LastideProtocol.ciphersuite, info: info)
    }
    let header = try EnvelopeHeader(kind: kind, flags: flags, slot: slot, sender: sender, recipient: recipient,
                                    seq: seq, enc: context.encapsulatedKey).bytes
    let ciphertext = try context.seal(plaintext, authenticating: header)
    return SealedEnvelope(bytes: header + ciphertext, seq: seq)
}
