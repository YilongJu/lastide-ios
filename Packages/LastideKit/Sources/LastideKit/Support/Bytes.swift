import Foundation

enum SecureRandom {
    /// Bytes from the system's cryptographic generator.
    static func bytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        var data = Data(capacity: count)
        for _ in 0..<count { data.append(UInt8.random(in: 0...255, using: &generator)) }
        return data
    }
}

enum HexError: Error { case notHex }

extension Data {
    init(hex: String) throws {
        let characters = Array(hex.utf8)
        guard characters.count % 2 == 0 else { throw HexError.notHex }
        var data = Data(capacity: characters.count / 2)
        var index = 0
        while index < characters.count {
            guard let high = Self.nibble(characters[index]), let low = Self.nibble(characters[index + 1]) else {
                throw HexError.notHex
            }
            data.append(high << 4 | low)
            index += 2
        }
        self = data
    }

    var hex: String {
        let digits = Array("0123456789abcdef".utf8)
        var output: [UInt8] = []
        output.reserveCapacity(count * 2)
        for byte in self {
            output.append(digits[Int(byte >> 4)])
            output.append(digits[Int(byte & 15)])
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 48...57: return c - 48
        case 97...102: return c - 87
        default: return nil
        }
    }
}
