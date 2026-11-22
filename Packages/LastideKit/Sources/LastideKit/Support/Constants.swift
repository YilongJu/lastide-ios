import Crypto
import Foundation

/// The fixed values of protocol version 1 (Table 2).
public enum LastideProtocol {
    /// Envelope byte 0, the version in the QR string and `v` in control frames.
    public static let version: UInt8 = 1
    /// The WebSocket subprotocol every socket offers.
    public static let webSocketSubprotocol = "lastide-relay.1"
    /// The sync schema revision this package speaks. Revision 2 adds the drafting run counts, the waiting
    /// import principles and the review comment evidence item (protocol 7.3).
    public static let schemaRevision = 2
    /// DHKEM(X25519, HKDF-SHA256), HKDF-SHA256, ChaCha20Poly1305.
    public static let ciphersuite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly
    /// Size of the clear envelope header.
    public static let headerSize = 76
    /// Size of the AEAD tag.
    public static let tagSize = 16
    /// Smallest envelope: a header and the tag of an empty plaintext.
    public static let smallestEnvelope = 92
    /// Largest envelope, header included.
    public static let largestEnvelope = 262_144
    /// Largest plaintext that fits the largest envelope.
    public static let largestPlaintext = 262_052
    /// Largest control frame in UTF-8 bytes.
    public static let largestControlFrame = 32_768
    /// `seq` stays below 2^53.
    public static let seqLimit: UInt64 = 1 << 53
    /// The largest JSON integer, 2^53 - 1.
    public static let largestInteger = 9_007_199_254_740_991
    /// The phone resends an outbox decision whose last send is more than 6 days old (section 6.9).
    public static let outboxResendAgeMs = 518_400_000
    /// The id of the disclosure the person accepts before the first scan.
    public static let disclosureID = "outside-ai-v1"
    /// The disclosure text the phone shows before the first scan (section 4.3, step 4).
    public static let disclosureText =
        "Rules you approve or edit here are used by an outside AI service on your PC. That service checks your later messages against them and drafts changes."
    /// The longest edit text the phone may send, in code points.
    public static let largestEditText = 500
}
