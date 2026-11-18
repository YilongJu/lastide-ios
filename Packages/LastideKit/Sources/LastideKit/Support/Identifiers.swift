import Foundation

/// A 16-byte device id that names a sender or a recipient in the room. The PC's device id is 16 zero bytes.
public struct DeviceID: Hashable, Sendable, Codable, CustomStringConvertible {
    /// The 16 raw bytes.
    public let bytes: Data

    /// Wraps 16 raw bytes.
    public init(bytes: Data) throws {
        guard bytes.count == 16 else { throw Base64URLError.wrongLength(expected: 16, actual: bytes.count) }
        self.bytes = Data(bytes)
    }

    /// Decodes 22 characters of canonical base64url.
    public init(base64url: String) throws { try self.init(bytes: Base64URL.decode(base64url, byteCount: 16)) }

    /// The PC's device id, 16 zero bytes.
    public static let pc = try! DeviceID(bytes: Data(count: 16))

    /// A fresh phone device id. The phone draws again on an all-zero result (section 2.2).
    public static func random() -> DeviceID {
        while true {
            let id = try! DeviceID(bytes: SecureRandom.bytes(16))
            if id != .pc { return id }
        }
    }

    /// The id as 22 characters of base64url.
    public var base64url: String { Base64URL.encode(bytes) }
    public var description: String { base64url }

    public init(from decoder: Decoder) throws { try self.init(base64url: decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(base64url)
    }
}

/// The 16 random bytes that name one PC's room.
public struct PairingID: Hashable, Sendable, Codable, CustomStringConvertible {
    /// The 16 raw bytes.
    public let bytes: Data

    /// Wraps 16 raw bytes.
    public init(bytes: Data) throws {
        guard bytes.count == 16 else { throw Base64URLError.wrongLength(expected: 16, actual: bytes.count) }
        self.bytes = Data(bytes)
    }

    /// Decodes 22 characters of canonical base64url.
    public init(base64url: String) throws { try self.init(bytes: Base64URL.decode(base64url, byteCount: 16)) }

    /// The id as 22 characters of base64url.
    public var base64url: String { Base64URL.encode(bytes) }
    public var description: String { base64url }

    public init(from decoder: Decoder) throws { try self.init(base64url: decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(base64url)
    }
}

/// The 16 random bytes of one QR code that let one phone open a pairing socket.
public struct PairingTicket: Hashable, Sendable, CustomStringConvertible {
    /// The 16 raw bytes.
    public let bytes: Data

    /// Wraps 16 raw bytes.
    public init(bytes: Data) throws {
        guard bytes.count == 16 else { throw Base64URLError.wrongLength(expected: 16, actual: bytes.count) }
        self.bytes = Data(bytes)
    }

    /// The ticket as 22 characters of base64url.
    public var base64url: String { Base64URL.encode(bytes) }
    public var description: String { base64url }
}

/// Makes a fresh message id: base64url of 16 random bytes (section 7.1).
public func makeMessageID() -> String { Base64URL.encode(SecureRandom.bytes(16)) }
