import Foundation

/// A control frame from the relay to the phone (Table 15). Unknown fields are ignored.
public enum RelayFrame: Hashable, Sendable {
    /// The relay accepted the `hello`.
    case welcome(Welcome)
    /// A peer came online or went offline.
    case presence(device: DeviceID, online: Bool)
    /// The control frame with that `rid` took effect.
    case ok(rid: String)
    /// The control frame with that `rid` did not take effect. `rid` is nil when that frame carried no valid `rid`.
    case refused(rid: String?, code: String)
    /// The relay put the envelope with that `seq` in the mailbox.
    case stored(to: DeviceID, seq: UInt64)
    /// The relay discarded the envelope with that `seq`.
    case dropped(to: DeviceID, seq: UInt64, reason: String)
    /// The answer to the text frame `ping`.
    case pong
}

/// The fields of `welcome` that a version 1 phone reads.
/// `pcOnline` is never nil for the `phone` and `pairing` roles, because `ControlFrame.parse` refuses such a `welcome` without it.
public struct Welcome: Hashable, Sendable {
    public let role: String
    public let device: DeviceID?
    public let features: [String]
    public let pcOnline: Bool?
    public let pcLastSeenAt: Int?
    public let mailbox: Int
    /// The 32 random bytes of a pairing socket's App Attest challenge, while the relay runs phase 7 (protocol 9.6).
    /// Always nil for the other roles.
    public let attestChallenge: Data?
}

/// The token types of a `push-token` frame (protocol 9.2).
public enum PushTokenType: String, Sendable, CaseIterable {
    /// The app's device token for alert and background pushes.
    case alert
    /// The widget extension's token for widget pushes.
    case widgets
}

/// The APNs host a device token belongs to (protocol 9.2).
public enum PushEnvironment: String, Sendable, CaseIterable {
    case sandbox, production

    /// Maps the `aps-environment` entitlement value: `development` reports `sandbox` (design section 4.3).
    public init?(entitlement: String) {
        switch entitlement {
        case "development": self = .sandbox
        case "production": self = .production
        default: return nil
        }
    }
}

/// Why a control frame from the relay was refused.
public enum ControlFrameError: Error, Equatable, Sendable {
    case tooLarge
    case notJSON
    case unknownOp(String)
    case badField(String)
}

/// Builds and parses the control frames the phone uses (section 6.4).
public enum ControlFrame {
    /// The text frame a device sends every 30 s.
    public static let ping = "ping"

    /// The `hello` of a paired phone.
    public static func helloPhone(device: DeviceID, token: Data) -> String {
        precondition(token.count == 32, "a phone token holds 32 bytes")
        return json(["op": "hello", "v": 1, "role": "phone", "device": device.base64url, "token": Base64URL.encode(token)])
    }

    /// The `hello` of a pairing socket.
    public static func helloPairing(ticket: PairingTicket) -> String {
        json(["op": "hello", "v": 1, "role": "pairing", "ticket": ticket.base64url])
    }

    /// The `push-token` frame of protocol 9.2. A nil token removes that token at the relay.
    public static func pushToken(rid: String, type: PushTokenType, token: Data?, environment: PushEnvironment) -> String {
        if let token { precondition((16...100).contains(token.count), "a device token holds 16 to 100 bytes") }
        return json(["op": "push-token", "rid": rid, "pushType": type.rawValue,
                     "token": token.map { $0.hex as Any } ?? NSNull(), "env": environment.rawValue])
    }

    /// The `attest` frame of protocol 9.6. `keyId` is App Attest's standard base64 text, as `generateKey` returns it.
    public static func attest(rid: String, keyId: String, attestation: Data, pairRequestHash: Data) -> String {
        precondition(pairRequestHash.count == 32, "the pair request hash holds 32 bytes")
        return json(["op": "attest", "rid": rid, "keyId": keyId, "attestation": Base64URL.encode(attestation),
                     "pairRequestHash": Base64URL.encode(pairRequestHash)])
    }

    /// The `received` frame: every envelope from `from` up to `upTo` is handled.
    public static func received(from: DeviceID, upTo: UInt64) -> String {
        json(["op": "received", "from": from.base64url, "upTo": upTo])
    }

    /// Parses one text frame from the relay.
    public static func parse(_ text: String) throws -> RelayFrame {
        guard text.utf8.count <= LastideProtocol.largestControlFrame else { throw ControlFrameError.tooLarge }
        if text == "pong" { return .pong }
        let f: Fields
        do { f = try JSONDecoder().decode(Fields.self, from: Data(text.utf8)) } catch { throw ControlFrameError.notJSON }
        switch f.op {
        case "welcome":
            guard f.v == 1 else { throw ControlFrameError.badField("v") }
            guard f.hasDevice else { throw ControlFrameError.badField("device") }
            let device = try f.device.map { try deviceID($0, "device") }
            let role = try need(f.role, "role")
            // Table 15: `welcome` carries `pcOnline` for the `phone` and `pairing` roles.
            if role == "phone" || role == "pairing" { _ = try need(f.pcOnline, "pcOnline") }
            // Only a pairing socket reads the challenge. Other roles ignore the field, as protocol 9.7 says.
            var challenge: Data?
            if role == "pairing", let text = f.attestChallenge {
                guard let bytes = try? Base64URL.decode(text, byteCount: 32) else { throw ControlFrameError.badField("attestChallenge") }
                challenge = bytes
            }
            return .welcome(Welcome(role: role, device: device, features: try need(f.features, "features"),
                                    pcOnline: f.pcOnline, pcLastSeenAt: f.pcLastSeenAt,
                                    mailbox: try count(f.mailbox, "mailbox"), attestChallenge: challenge))
        case "presence":
            return .presence(device: try deviceID(need(f.device, "device"), "device"), online: try need(f.online, "online"))
        case "ok":
            return .ok(rid: try need(f.rid, "rid"))
        case "refused":
            guard f.hasRid else { throw ControlFrameError.badField("rid") }
            return .refused(rid: f.rid, code: try need(f.code, "code"))
        case "stored":
            return .stored(to: try deviceID(need(f.to, "to"), "to"), seq: UInt64(try count(f.seq, "seq")))
        case "dropped":
            return .dropped(to: try deviceID(need(f.to, "to"), "to"), seq: UInt64(try count(f.seq, "seq")),
                            reason: try need(f.reason, "reason"))
        default:
            throw ControlFrameError.unknownOp(f.op)
        }
    }

    private struct Fields: Decodable {
        let op: String
        let v: Int?
        let role: String?
        let hasDevice: Bool
        let device: String?
        let features: [String]?
        let pcOnline: Bool?
        let pcLastSeenAt: Int?
        let mailbox: Int?
        let online: Bool?
        let hasRid: Bool
        let rid: String?
        let code: String?
        let to: String?
        let seq: Int?
        let reason: String?
        let attestChallenge: String?

        enum CodingKeys: String, CodingKey {
            case op, v, role, device, features, pcOnline, pcLastSeenAt, mailbox, online, rid, code, to, seq, reason
            case attestChallenge
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            op = try c.decode(String.self, forKey: .op)
            v = try c.decodeIfPresent(Int.self, forKey: .v)
            role = try c.decodeIfPresent(String.self, forKey: .role)
            hasDevice = c.contains(.device)
            device = try c.decodeIfPresent(String.self, forKey: .device)
            features = try c.decodeIfPresent([String].self, forKey: .features)
            pcOnline = try c.decodeIfPresent(Bool.self, forKey: .pcOnline)
            pcLastSeenAt = try c.decodeIfPresent(Int.self, forKey: .pcLastSeenAt)
            mailbox = try c.decodeIfPresent(Int.self, forKey: .mailbox)
            online = try c.decodeIfPresent(Bool.self, forKey: .online)
            hasRid = c.contains(.rid)
            rid = try c.decodeIfPresent(String.self, forKey: .rid)
            code = try c.decodeIfPresent(String.self, forKey: .code)
            to = try c.decodeIfPresent(String.self, forKey: .to)
            seq = try c.decodeIfPresent(Int.self, forKey: .seq)
            reason = try c.decodeIfPresent(String.self, forKey: .reason)
            attestChallenge = try c.decodeIfPresent(String.self, forKey: .attestChallenge)
        }
    }

    private static func need<T>(_ value: T?, _ key: String) throws -> T {
        guard let value else { throw ControlFrameError.badField(key) }
        return value
    }

    private static func count(_ value: Int?, _ key: String) throws -> Int {
        guard let value, value >= 0, value <= LastideProtocol.largestInteger else { throw ControlFrameError.badField(key) }
        return value
    }

    private static func deviceID(_ value: String, _ key: String) throws -> DeviceID {
        guard let id = try? DeviceID(base64url: value) else { throw ControlFrameError.badField(key) }
        return id
    }

    private static func json(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
}

/// A WebSocket close code from the relay, with what the phone does (Table 17).
public enum RelayCloseCode: Int, Sendable, CaseIterable {
    case normal = 1000
    case badFrame = 4400
    case unauthorized = 4401
    case attestationRefused = 4402
    case forbidden = 4403
    case roomGone = 4404
    case timeout = 4408
    case replaced = 4409
    case revoked = 4410
    case tooLarge = 4413
    case unsupportedVersion = 4426
    case rateLimited = 4429
    case relayError = 4500
    case pcOffline = 4503

    /// The sentence the phone shows, or nil when the phone only logs the code. `pairing` is true on a pairing socket.
    public func displayText(pairing: Bool) -> String? {
        switch self {
        case .unauthorized:
            return pairing ? "This code no longer works. Show a new code on your PC." : "This PC no longer accepts this phone."
        case .attestationRefused: return "Pairing needs the App Store or TestFlight build of Lastide."
        case .revoked: return "This PC removed this phone."
        case .unsupportedVersion: return "Update the Lastide app."
        case .pcOffline: return "Open Lastide on your PC and show a new code."
        default: return nil
        }
    }

    /// Whether the device opens a new socket after this close.
    public var reconnects: Bool {
        switch self {
        case .timeout, .rateLimited, .relayError: return true
        default: return false
        }
    }
}

/// The reconnect wait of section 6.8: 1 s, doubled after each try, up to 5 minutes.
public struct ReconnectBackoff: Hashable, Sendable {
    /// The wait before the next try, in ms.
    public private(set) var nextWaitMs = 1_000

    /// Starts at 1 s.
    public init() {}

    /// Returns the wait for this try and doubles the next one.
    public mutating func take() -> Int {
        let wait = nextWaitMs
        nextWaitMs = min(nextWaitMs * 2, 300_000)
        return wait
    }

    /// A `welcome`, or the app's return to the screen, resets the wait to 1 s.
    public mutating func reset() { nextWaitMs = 1_000 }
}
