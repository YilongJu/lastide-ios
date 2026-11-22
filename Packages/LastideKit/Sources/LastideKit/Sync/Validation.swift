import Foundation

/// A sync message that broke one constraint of section 7.3. `path` names the field, `rule` the constraint.
public struct ValidationError: Error, Equatable, Sendable, CustomStringConvertible {
    public let path: String
    public let rule: String
    public var description: String { "\(path): \(rule)" }
}

/// A type whose constraints section 7.3 states.
protocol Validatable {
    func validate(_ path: String) throws
}

/// The checks behind every constraint in `Constraints.md`.
enum Check {
    static func that(_ condition: Bool, _ path: String, _ rule: String) throws {
        if !condition { throw ValidationError(path: path, rule: rule) }
    }

    /// `time`, `count` and `storeVersion`: an integer from 0 to 2^53 - 1.
    static func integer(_ value: Int, _ path: String) throws {
        try that(value >= 0 && value <= LastideProtocol.largestInteger, path, "integer from 0 to 2^53 - 1")
    }

    static func optionalInteger(_ value: Int?, _ path: String) throws {
        if let value { try integer(value, path) }
    }

    /// `schemaRevision`: 1 to 65535.
    static func schemaRevision(_ value: Int, _ path: String) throws {
        try that(value >= 1 && value <= 65535, path, "schema revision from 1 to 65535")
    }

    /// `b64u16`: canonical base64url of 16 bytes.
    static func b64u16(_ value: String, _ path: String) throws {
        try that((try? Base64URL.decode(value, byteCount: 16)) != nil && value.utf8.count == 22, path, "base64url of 16 bytes")
    }

    /// `b64u32`: canonical base64url of 32 bytes.
    static func b64u32(_ value: String, _ path: String) throws {
        try that((try? Base64URL.decode(value, byteCount: 32)) != nil && value.utf8.count == 43, path, "base64url of 32 bytes")
    }

    /// `itemId`: `^[A-Za-z0-9._:-]{1,64}$`.
    static func itemID(_ value: String, _ path: String) throws {
        try characters(value, extra: "._:-", maximum: 64, path, "item id")
    }

    /// `^[A-Za-z0-9_-]{1,16}$`, used by scope option ids and evidence ids.
    static func shortID(_ value: String, _ path: String) throws {
        try characters(value, extra: "_-", maximum: 16, path, "short id")
    }

    /// `model`: `^[A-Za-z0-9,._-]{1,32}$`.
    static func model(_ value: String, _ path: String) throws {
        try characters(value, extra: ",._-", maximum: 32, path, "model identifier")
    }

    /// A string whose length in code points lies between the bounds, as JSON Schema counts it.
    static func text(_ value: String, _ path: String, minimum: Int, maximum: Int) throws {
        let length = value.unicodeScalars.count
        try that(length >= minimum && length <= maximum, path, "length from \(minimum) to \(maximum) code points")
    }

    /// `^[^\r\n]+$`: no carriage return and no line feed.
    static func oneLine(_ value: String, _ path: String) throws {
        try that(!value.unicodeScalars.contains { $0 == "\r" || $0 == "\n" }, path, "one line")
    }

    /// `commentLabel`: `^C[0-9]{1,9}$`.
    static func commentLabel(_ value: String, _ path: String) throws {
        let bytes = Array(value.utf8)
        let shape = bytes.count >= 2 && bytes.count <= 10 && bytes[0] == UInt8(ascii: "C") && bytes.dropFirst().allSatisfy { (48...57).contains($0) }
        try that(shape, path, "comment label as C and 1 to 9 digits")
    }

    /// `weekStart`: `^[0-9]{4}-[0-9]{2}-[0-9]{2}$`.
    static func weekStart(_ value: String, _ path: String) throws {
        let bytes = Array(value.utf8)
        let shape = bytes.count == 10 && bytes.enumerated().allSatisfy { index, byte in
            index == 4 || index == 7 ? byte == UInt8(ascii: "-") : (48...57).contains(byte)
        }
        try that(shape, path, "date as YYYY-MM-DD")
    }

    static func unique<T: Hashable>(_ values: [T], _ path: String) throws {
        try that(Set(values).count == values.count, path, "unique items")
    }

    static func count<T>(_ values: [T], _ path: String, minimum: Int, maximum: Int) throws {
        try that(values.count >= minimum && values.count <= maximum, path, "from \(minimum) to \(maximum) items")
    }

    private static func characters(_ value: String, extra: String, maximum: Int, _ path: String, _ name: String) throws {
        let allowed = Set(extra.utf8)
        let bytes = Array(value.utf8)
        let fits = !bytes.isEmpty && bytes.count <= maximum && bytes.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || allowed.contains(byte)
        }
        try that(fits, path, name)
    }
}

extension KeyedDecodingContainer {
    /// Decodes a field that must be present and may be null.
    func nullable<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? {
        try decode(T?.self, forKey: key)
    }
}

extension KeyedEncodingContainer {
    /// Encodes a field that is always present and may be null.
    mutating func encodeNullable<T: Encodable>(_ value: T?, forKey key: Key) throws {
        if let value { try encode(value, forKey: key) } else { try encodeNil(forKey: key) }
    }
}
