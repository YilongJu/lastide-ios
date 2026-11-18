import Crypto
import Foundation
@testable import LastideKit
import XCTest

final class Base64URLTests: XCTestCase {
    func testRoundTripAndLengths() throws {
        for count in 0..<40 {
            let bytes = SecureRandom.bytes(count)
            XCTAssertEqual(try Base64URL.decode(Base64URL.encode(bytes)), bytes)
        }
        XCTAssertEqual(Base64URL.encode(Data(count: 16)).count, 22)
        XCTAssertEqual(Base64URL.encode(Data(count: 32)).count, 43)
    }

    func testRefusesPaddingForeignCharactersAndSetUnusedBits() {
        XCTAssertThrowsError(try Base64URL.decode("AAAAAAAAAAAAAAAAAAAAAA=="))
        XCTAssertThrowsError(try Base64URL.decode("AAAAAAAAAAAAAAAAAAAA+A"))
        XCTAssertThrowsError(try Base64URL.decode("AAAAAAAAAAAAAAAAAAAA/A"))
        XCTAssertThrowsError(try Base64URL.decode("AAAAAAAAAAAAAAAAAAAAAB"), "unused bits set")
        XCTAssertThrowsError(try Base64URL.decode("A"), "one character holds no byte")
        XCTAssertThrowsError(try Base64URL.decode("AAAAAAAAAAAAAAAAAAAAAA", byteCount: 32))
        XCTAssertNoThrow(try Base64URL.decode("AAAAAAAAAAAAAAAAAAAAAw", byteCount: 16))
    }
}

final class EnvelopeHeaderTests: XCTestCase {
    let enc = Data(repeating: 7, count: 32)
    let phone = try! DeviceID(bytes: Data(repeating: 9, count: 16))

    func frame(_ edit: (inout [UInt8]) -> Void, size: Int = 92) throws -> Data {
        let header = try EnvelopeHeader(kind: .message, flags: .mailbox, slot: 1, sender: .pc, recipient: phone, seq: 5, enc: enc)
        var bytes = [UInt8](header.bytes) + [UInt8](repeating: 0, count: size - 76)
        edit(&bytes)
        return Data(bytes)
    }

    func testRoundTrip() throws {
        let header = try EnvelopeHeader(kind: .message, flags: [.mailbox], slot: 2, sender: phone, recipient: .pc,
                                        seq: 1_794_992_400_000, enc: enc)
        XCTAssertEqual(header.bytes.count, 76)
        XCTAssertEqual(try EnvelopeHeader(frame: header.bytes + Data(count: 16)), header)
    }

    func testReceiverRefusesEachBadField() throws {
        XCTAssertThrowsError(try EnvelopeHeader(frame: frame({ _ in }, size: 91)))
        XCTAssertThrowsError(try EnvelopeHeader(frame: frame({ _ in }, size: 262_145)))
        XCTAssertNoThrow(try EnvelopeHeader(frame: frame({ _ in }, size: 262_144)))
        XCTAssertThrowsError(try EnvelopeHeader(frame: frame { $0[0] = 2 }))
        XCTAssertThrowsError(try EnvelopeHeader(frame: frame { $0[1] = 0 }))
        XCTAssertThrowsError(try EnvelopeHeader(frame: frame { $0[1] = 5 }))
        for bit in 2..<8 { XCTAssertThrowsError(try EnvelopeHeader(frame: frame { $0[2] = UInt8(1 << bit) })) }
        XCTAssertThrowsError(try EnvelopeHeader(frame: frame { $0[3] = 3 }))
        XCTAssertThrowsError(try EnvelopeHeader(frame: frame { for i in 36..<44 { $0[i] = 0 } }), "seq 0")
        XCTAssertThrowsError(try EnvelopeHeader(frame: frame { for i in 36..<44 { $0[i] = 0 }; $0[37] = 0x20 }), "seq 2^53")
        XCTAssertNoThrow(try EnvelopeHeader(frame: frame { for i in 36..<44 { $0[i] = 0xFF }; $0[36] = 0; $0[37] = 0x1F }))
    }

    func testRelayChecksGiveTheCloseCodesOfSection65() throws {
        XCTAssertNil(relayHeaderCheck(try frame { _ in }))
        XCTAssertEqual(relayHeaderCheck(try frame({ _ in }, size: 91)), 4400)
        XCTAssertEqual(relayHeaderCheck(try frame({ _ in }, size: 262_145)), 4413)
        XCTAssertEqual(relayHeaderCheck(try frame { $0[0] = 0 }), 4400)
        XCTAssertEqual(relayHeaderCheck(try frame { $0[1] = 5 }), 4400)
        XCTAssertEqual(relayHeaderCheck(try frame { $0[2] = 0x05 }), 4400)
        XCTAssertEqual(relayHeaderCheck(try frame { for i in 36..<44 { $0[i] = 0 } }), 4400)
        // Check 6: flags and slot per kind.
        XCTAssertEqual(relayHeaderCheck(try frame { $0[1] = 1; $0[2] = 0; $0[3] = 1 }), 4400)
        XCTAssertNil(relayHeaderCheck(try frame { $0[1] = 1; $0[2] = 0; $0[3] = 0 }))
        XCTAssertNil(relayHeaderCheck(try frame { $0[1] = 2; $0[2] = 0; $0[3] = 1 }))
        XCTAssertEqual(relayHeaderCheck(try frame { $0[1] = 2; $0[2] = 0; $0[3] = 2 }), 4400)
        XCTAssertEqual(relayHeaderCheck(try frame { $0[1] = 2; $0[2] = 1; $0[3] = 0 }), 4400)
        XCTAssertEqual(relayHeaderCheck(try frame { $0[2] = 0x03 }), 4400, "MAILBOX with REPLY_KEY")
        XCTAssertEqual(relayHeaderCheck(try frame { $0[2] = 0x01; $0[3] = 3 }), 4400)
        XCTAssertEqual(relayHeaderCheck(try frame { $0[2] = 0x00; $0[3] = 1 }), 4400, "live-only kind 3 in slot 1")
        XCTAssertNil(relayHeaderCheck(try frame { $0[2] = 0x02; $0[3] = 0 }), "REPLY_KEY in slot 0")
        XCTAssertEqual(relayHeaderCheck(try frame { $0[1] = 4; $0[2] = 0x01; $0[3] = 0 }), 4400)
    }

    func testSequenceCounterUsesTheClockAsAFloorAndStopsBelowTwoToThe53() throws {
        var counter = SequenceCounter(lastSentSeq: 0)
        XCTAssertEqual(try counter.next(now: 1_000), 1_000)
        XCTAssertEqual(try counter.next(now: 1_000), 1_001)
        XCTAssertEqual(try counter.next(now: 500), 1_002, "a clock that went back still raises seq")
        XCTAssertEqual(try counter.next(now: 5_000), 5_000)
        XCTAssertEqual(counter.lastSentSeq, 5_000)
        var last = SequenceCounter(lastSentSeq: LastideProtocol.seqLimit - 2)
        XCTAssertEqual(try last.next(now: 0), LastideProtocol.seqLimit - 1)
        XCTAssertThrowsError(try last.next(now: 0))
        XCTAssertEqual(last.lastSentSeq, LastideProtocol.seqLimit - 1)
    }

    func testCheckCodeKeepsLeadingZeros() throws {
        XCTAssertEqual(CheckCode(exported: try Data(hex: "9c110ed03f0e1a16")).digits, "714390")
        XCTAssertEqual(CheckCode(exported: Data(count: 8)).digits, "000000")
        XCTAssertEqual(CheckCode(exported: Data([0, 0, 0, 0, 0, 0, 0, 42])).display, "000 042")
    }

    func testDeviceIDs() throws {
        XCTAssertEqual(DeviceID.pc.base64url, "AAAAAAAAAAAAAAAAAAAAAA")
        XCTAssertNotEqual(DeviceID.random(), .pc)
        XCTAssertThrowsError(try DeviceID(bytes: Data(count: 15)))
        XCTAssertThrowsError(try DeviceID(base64url: "AAAAAAAAAAAAAAAAAAAAAB"))
        XCTAssertEqual(makeMessageID().count, 22)
    }
}
