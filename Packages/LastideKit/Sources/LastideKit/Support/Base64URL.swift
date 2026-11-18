import Foundation

/// Base64url without padding (RFC 4648 section 5), with the strict decoding rules of the protocol's notation section.
public enum Base64URL {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8)
    private static let values: [UInt8: UInt8] = {
        var table: [UInt8: UInt8] = [:]
        for (index, character) in alphabet.enumerated() { table[character] = UInt8(index) }
        return table
    }()

    /// Encodes bytes without padding.
    public static func encode<Bytes: DataProtocol>(_ bytes: Bytes) -> String {
        let input = Array(bytes)
        var output: [UInt8] = []
        output.reserveCapacity((input.count * 4 + 2) / 3)
        var index = 0
        while index + 3 <= input.count {
            let n = UInt32(input[index]) << 16 | UInt32(input[index + 1]) << 8 | UInt32(input[index + 2])
            output.append(alphabet[Int(n >> 18 & 63)])
            output.append(alphabet[Int(n >> 12 & 63)])
            output.append(alphabet[Int(n >> 6 & 63)])
            output.append(alphabet[Int(n & 63)])
            index += 3
        }
        let rest = input.count - index
        if rest == 1 {
            let n = UInt32(input[index]) << 16
            output.append(alphabet[Int(n >> 18 & 63)])
            output.append(alphabet[Int(n >> 12 & 63)])
        } else if rest == 2 {
            let n = UInt32(input[index]) << 16 | UInt32(input[index + 1]) << 8
            output.append(alphabet[Int(n >> 18 & 63)])
            output.append(alphabet[Int(n >> 12 & 63)])
            output.append(alphabet[Int(n >> 6 & 63)])
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// Decodes canonical base64url. Refuses padding, characters outside the alphabet and a final character with unused bits set.
    public static func decode(_ text: String) throws -> Data {
        let input = Array(text.utf8)
        if input.count % 4 == 1 { throw Base64URLError.notCanonical }
        var digits: [UInt8] = []
        digits.reserveCapacity(input.count)
        for character in input {
            guard let value = values[character] else { throw Base64URLError.notCanonical }
            digits.append(value)
        }
        var output = Data()
        var index = 0
        while index + 4 <= digits.count {
            let n = UInt32(digits[index]) << 18 | UInt32(digits[index + 1]) << 12
                | UInt32(digits[index + 2]) << 6 | UInt32(digits[index + 3])
            output.append(UInt8(n >> 16 & 255))
            output.append(UInt8(n >> 8 & 255))
            output.append(UInt8(n & 255))
            index += 4
        }
        let rest = digits.count - index
        if rest == 2 {
            if digits[index + 1] & 0x0F != 0 { throw Base64URLError.notCanonical }
            output.append(digits[index] << 2 | digits[index + 1] >> 4)
        } else if rest == 3 {
            if digits[index + 2] & 0x03 != 0 { throw Base64URLError.notCanonical }
            output.append(digits[index] << 2 | digits[index + 1] >> 4)
            output.append((digits[index + 1] & 0x0F) << 4 | digits[index + 2] >> 2)
        }
        return output
    }

    /// Decodes canonical base64url and requires an exact byte count.
    public static func decode(_ text: String, byteCount: Int) throws -> Data {
        let data = try decode(text)
        guard data.count == byteCount else { throw Base64URLError.wrongLength(expected: byteCount, actual: data.count) }
        return data
    }
}

/// Why a base64url string was refused.
public enum Base64URLError: Error, Equatable, Sendable {
    case notCanonical
    case wrongLength(expected: Int, actual: Int)
}
