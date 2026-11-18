import Foundation

/// The direction of a sync message.
public enum Direction: Sendable { case phoneToPC, pcToPhone, both }

/// The `type` of a sync message, with its route from Table 20.
public enum MessageType: String, Sendable, CaseIterable {
    case pairRequest = "pair-request"
    case pairReceived = "pair-received"
    case pairAccept = "pair-accept"
    case pairRefuse = "pair-refuse"
    case queue
    case library
    case counts
    case evidence
    case acknowledgement
    case decision
    case sync
    case evidenceRequest = "evidence-request"
    case unpair
    case error
    case notice

    /// The envelope kind that carries this type.
    public var kind: EnvelopeKind {
        switch self {
        case .pairRequest: return .pairRequest
        case .pairReceived, .pairAccept, .pairRefuse: return .pairReply
        case .notice: return .push
        default: return .message
        }
    }

    /// Who sends this type.
    public var direction: Direction {
        switch self {
        case .pairRequest, .decision, .sync, .evidenceRequest, .unpair: return .phoneToPC
        case .error: return .both
        default: return .pcToPhone
        }
    }

    /// The header flags this type travels with.
    public var flags: EnvelopeFlags {
        switch self {
        case .queue, .library, .acknowledgement, .decision, .unpair: return .mailbox
        case .evidence: return .replyKey
        default: return []
        }
    }

    /// The header slot this type travels in.
    public var slot: UInt8 {
        switch self {
        case .pairReceived, .queue: return 1
        case .library: return 2
        default: return 0
        }
    }
}

/// Why a plaintext could not be used. `code` is the code of the `error` reply (Table 12).
public struct MessageDecodingError: Error, Equatable, Sendable, CustomStringConvertible {
    public let code: ErrorCode
    public let detail: String
    /// The message id, when the plaintext held a valid one.
    public let messageID: String?
    /// The message type, when the plaintext named one.
    public let type: String?
    public var description: String { "\(code.rawValue): \(detail)" }
}

/// The fields every sync message carries.
protocol MessageBody: Codable, Validatable, Sendable {
    var id: String { get }
    var sentAt: Int { get }
}

extension PairRequest: MessageBody {}
extension PairReceived: MessageBody {}
extension PairAccept: MessageBody {}
extension PairRefuse: MessageBody {}
extension QueueSnapshot: MessageBody {}
extension LibrarySnapshot: MessageBody {}
extension Counts: MessageBody {}
extension Evidence: MessageBody {}
extension Acknowledgement: MessageBody {}
extension Decision: MessageBody {}
extension SyncRequest: MessageBody {}
extension EvidenceRequest: MessageBody {}
extension Unpair: MessageBody {}
extension ErrorMessage: MessageBody {}
extension Notice: MessageBody {}

/// One sync message of section 7, decoded and checked against every constraint of section 7.3.
public enum SyncMessage: Hashable, Sendable {
    case pairRequest(PairRequest)
    case pairReceived(PairReceived)
    case pairAccept(PairAccept)
    case pairRefuse(PairRefuse)
    case queue(QueueSnapshot)
    case library(LibrarySnapshot)
    case counts(Counts)
    case evidence(Evidence)
    case acknowledgement(Acknowledgement)
    case decision(Decision)
    case sync(SyncRequest)
    case evidenceRequest(EvidenceRequest)
    case unpair(Unpair)
    case error(ErrorMessage)
    case notice(Notice)

    /// The message's `type`.
    public var type: MessageType {
        switch self {
        case .pairRequest: return .pairRequest
        case .pairReceived: return .pairReceived
        case .pairAccept: return .pairAccept
        case .pairRefuse: return .pairRefuse
        case .queue: return .queue
        case .library: return .library
        case .counts: return .counts
        case .evidence: return .evidence
        case .acknowledgement: return .acknowledgement
        case .decision: return .decision
        case .sync: return .sync
        case .evidenceRequest: return .evidenceRequest
        case .unpair: return .unpair
        case .error: return .error
        case .notice: return .notice
        }
    }

    private var body: any MessageBody {
        switch self {
        case .pairRequest(let m): return m
        case .pairReceived(let m): return m
        case .pairAccept(let m): return m
        case .pairRefuse(let m): return m
        case .queue(let m): return m
        case .library(let m): return m
        case .counts(let m): return m
        case .evidence(let m): return m
        case .acknowledgement(let m): return m
        case .decision(let m): return m
        case .sync(let m): return m
        case .evidenceRequest(let m): return m
        case .unpair(let m): return m
        case .error(let m): return m
        case .notice(let m): return m
        }
    }

    /// The message's `id`.
    public var id: String { body.id }

    /// The sender's clock when it sent the message, in ms.
    public var sentAt: Int { body.sentAt }

    /// Checks every constraint of section 7.3, including `id` and `sentAt`.
    public func validate() throws {
        try Check.b64u16(body.id, "id")
        try Check.integer(body.sentAt, "sentAt")
        try body.validate("")
    }

    /// Decodes one plaintext. Throws `badMessage` or `unknownType` as Table 12 assigns them.
    public static func decode(_ plaintext: Data) throws -> SyncMessage {
        guard String(data: plaintext, encoding: .utf8) != nil else {
            throw MessageDecodingError(code: .badMessage, detail: "not UTF-8", messageID: nil, type: nil)
        }
        let probe: TypeProbe
        do {
            probe = try JSONDecoder().decode(TypeProbe.self, from: plaintext)
        } catch {
            throw MessageDecodingError(code: .badMessage, detail: "not a JSON object with a string type", messageID: nil, type: nil)
        }
        let messageID = probe.id.flatMap { (try? Check.b64u16($0, "id")) != nil ? $0 : nil }
        guard let type = MessageType(rawValue: probe.type) else {
            throw MessageDecodingError(code: .unknownType, detail: "unknown type", messageID: messageID, type: probe.type)
        }
        let decoder = JSONDecoder()
        let message: SyncMessage
        do {
            switch type {
            case .pairRequest: message = .pairRequest(try decoder.decode(PairRequest.self, from: plaintext))
            case .pairReceived: message = .pairReceived(try decoder.decode(PairReceived.self, from: plaintext))
            case .pairAccept: message = .pairAccept(try decoder.decode(PairAccept.self, from: plaintext))
            case .pairRefuse: message = .pairRefuse(try decoder.decode(PairRefuse.self, from: plaintext))
            case .queue: message = .queue(try decoder.decode(QueueSnapshot.self, from: plaintext))
            case .library: message = .library(try decoder.decode(LibrarySnapshot.self, from: plaintext))
            case .counts: message = .counts(try decoder.decode(Counts.self, from: plaintext))
            case .evidence: message = .evidence(try decoder.decode(Evidence.self, from: plaintext))
            case .acknowledgement: message = .acknowledgement(try decoder.decode(Acknowledgement.self, from: plaintext))
            case .decision: message = .decision(try decoder.decode(Decision.self, from: plaintext))
            case .sync: message = .sync(try decoder.decode(SyncRequest.self, from: plaintext))
            case .evidenceRequest: message = .evidenceRequest(try decoder.decode(EvidenceRequest.self, from: plaintext))
            case .unpair: message = .unpair(try decoder.decode(Unpair.self, from: plaintext))
            case .error: message = .error(try decoder.decode(ErrorMessage.self, from: plaintext))
            case .notice: message = .notice(try decoder.decode(Notice.self, from: plaintext))
            }
        } catch {
            throw MessageDecodingError(code: .badMessage, detail: "fails the schema of \(type.rawValue)",
                                       messageID: messageID, type: probe.type)
        }
        do {
            try message.validate()
        } catch let failure as ValidationError {
            throw MessageDecodingError(code: .badMessage, detail: "fails the schema of \(type.rawValue) at \(failure.path)",
                                       messageID: messageID, type: probe.type)
        }
        return message
    }

    /// The compact JSON plaintext. Checks every constraint first and throws `ValidationError` on a failure.
    public func encoded() throws -> Data {
        try validate()
        return try encodedWithoutCheck()
    }

    private func encodedWithoutCheck() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Wrapper(type: type.rawValue, body: body))
    }

    private struct TypeProbe: Decodable {
        let type: String
        let id: String?
        enum CodingKeys: String, CodingKey { case type, id }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try c.decode(String.self, forKey: .type)
            id = try? c.decode(String.self, forKey: .id)
        }
    }

    private struct Wrapper: Encodable {
        let type: String
        let body: any Encodable
        enum CodingKeys: String, CodingKey { case type }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(type, forKey: .type)
            try body.encode(to: encoder)
        }
    }
}
