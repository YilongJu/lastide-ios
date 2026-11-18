import Crypto
import Foundation

/// Why a scanned string is not a usable pairing code (section 3.2).
public enum QRError: Error, Equatable, Sendable {
    /// The string starts with `lastide-pair:` and names another protocol version.
    case otherVersion
    /// Any other string.
    case notPairingCode

    /// The sentence the phone shows.
    public var displayText: String {
        switch self {
        case .otherVersion: return "Update the Lastide app to pair with this PC."
        case .notPairingCode: return "This is not a Lastide pairing code."
        }
    }
}

/// The checked content of one pairing QR code (section 3).
///
/// The QR string holds no time. The relay refuses the ticket 120 s after the PC opens it, and the pairing
/// socket then closes with 4401 (section 3.3). `RelayCloseCode.unauthorized` gives the phone's sentence.
public struct QRPayload: Sendable {
    /// The PC's static public key.
    public let pcKey: Curve25519.KeyAgreement.PublicKey
    /// The room's pairing id.
    public let pairingID: PairingID
    /// The pairing ticket that the `hello` of the pairing socket carries.
    public let ticket: PairingTicket
    /// The relay origin, equal to one entry of the app's list.
    public let relayOrigin: String
    /// The `p` value as the QR code wrote it.
    public let pairingIDText: String

    /// Parses a scanned string against the app's built-in list of relay origins.
    public static func parse(_ text: String, relayOrigins: [String]) throws -> QRPayload {
        for origin in relayOrigins {
            precondition(isOrigin(origin), "a built-in relay origin is not a lowercase https origin without a path")
        }
        let prefix = "lastide-pair:"
        guard text.hasPrefix(prefix) else { throw QRError.notPairingCode }
        guard text.hasPrefix(prefix + "1?") else {
            let rest = text.dropFirst(prefix.count)
            let version = rest.prefix { $0 != "?" }
            if !version.isEmpty, version.allSatisfy({ $0.isASCII && $0.isNumber }) { throw QRError.otherVersion }
            throw QRError.notPairingCode
        }
        let query = text.dropFirst(prefix.count + 2)
        let parts = query.split(separator: "&", omittingEmptySubsequences: false)
        guard parts.count == 4 else { throw QRError.notPairingCode }
        var values: [String] = []
        for (part, name) in zip(parts, ["k", "p", "t", "r"]) {
            guard part.hasPrefix(name + "=") else { throw QRError.notPairingCode }
            values.append(String(part.dropFirst(2)))
        }
        guard let keyBytes = try? Base64URL.decode(values[0], byteCount: 32),
              let pcKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: keyBytes),
              let pairingID = try? PairingID(base64url: values[1]),
              let ticketBytes = try? Base64URL.decode(values[2], byteCount: 16),
              let ticket = try? PairingTicket(bytes: ticketBytes)
        else { throw QRError.notPairingCode }
        let encodedOrigin = values[3]
        guard encodedOrigin.utf8.count <= 64,
              let origin = percentDecode(encodedOrigin),
              encodeURIComponent(origin) == encodedOrigin,
              isOrigin(origin),
              relayOrigins.contains(origin)
        else { throw QRError.notPairingCode }
        return QRPayload(pcKey: pcKey, pairingID: pairingID, ticket: ticket, relayOrigin: origin, pairingIDText: values[1])
    }

    /// The socket URL: the origin with `wss://`, then `/api/relay/` and the `p` value as written.
    public var socketURL: URL {
        URL(string: "wss://" + relayOrigin.dropFirst("https://".count) + "/api/relay/" + pairingIDText)!
    }

    /// True for `https://`, a lowercase host and an optional port other than 443, with nothing after it.
    static func isOrigin(_ origin: String) -> Bool {
        guard origin.hasPrefix("https://") else { return false }
        let authority = origin.dropFirst("https://".count)
        let pieces = authority.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 1 || pieces.count == 2 else { return false }
        let host = pieces[0]
        let hostCharacters = Set("abcdefghijklmnopqrstuvwxyz0123456789.-")
        guard !host.isEmpty, host.allSatisfy({ hostCharacters.contains($0) }),
              !host.hasPrefix("."), !host.hasSuffix("."), !host.hasPrefix("-")
        else { return false }
        if pieces.count == 2 {
            let port = pieces[1]
            guard !port.isEmpty, port.count <= 5, port.allSatisfy({ $0.isASCII && $0.isNumber }), !port.hasPrefix("0"),
                  let number = Int(port), number <= 65535, number != 443
            else { return false }
        }
        return true
    }

    /// The characters `encodeURIComponent` leaves as they are.
    private static let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()".utf8)

    /// JavaScript's `encodeURIComponent` for the ASCII text an origin holds.
    static func encodeURIComponent(_ text: String) -> String {
        var output = ""
        for byte in text.utf8 {
            if unreserved.contains(byte) {
                output.append(Character(UnicodeScalar(byte)))
            } else {
                output += "%" + String(byte, radix: 16, uppercase: true).leftPadded(to: 2)
            }
        }
        return output
    }

    private static func percentDecode(_ text: String) -> String? {
        var bytes: [UInt8] = []
        var iterator = Array(text.utf8).makeIterator()
        while let byte = iterator.next() {
            if byte == UInt8(ascii: "%") {
                guard let high = iterator.next(), let low = iterator.next(),
                      let value = UInt8(String(decoding: [high, low], as: UTF8.self), radix: 16)
                else { return nil }
                bytes.append(value)
            } else {
                bytes.append(byte)
            }
        }
        return String(bytes: bytes, encoding: .utf8)
    }
}

private extension String {
    func leftPadded(to width: Int) -> String { String(repeating: "0", count: max(0, width - count)) + self }
}
