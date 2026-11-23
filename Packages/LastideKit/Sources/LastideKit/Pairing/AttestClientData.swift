import Crypto
import Foundation

/// The client data that binds an App Attest attestation to one pairing socket and one pair request (protocol 9.6).
///
/// `clientData = "lastide/v1/attest" || 0x00 || challenge || h1`, 18 + 32 + 32 = 82 bytes. The phone passes its SHA-256
/// to `attestKey(_:clientDataHash:)`, and the relay computes the same hash from the socket's challenge.
public enum AttestClientData {
    /// The label before the zero byte.
    public static let label = "lastide/v1/attest"

    /// The 82 bytes. `challenge` is the 32 bytes of `welcome.attestChallenge`, `pairRequestHash` the pair request's `h1`.
    public static func bytes(challenge: Data, pairRequestHash: Data) -> Data {
        precondition(challenge.count == 32, "the attest challenge holds 32 bytes")
        precondition(pairRequestHash.count == 32, "the pair request hash holds 32 bytes")
        var data = Data(label.utf8)
        data.append(0)
        data.append(challenge)
        data.append(pairRequestHash)
        return data
    }

    /// SHA-256 of the client data, which the phone passes to App Attest.
    public static func hash(challenge: Data, pairRequestHash: Data) -> Data {
        Data(SHA256.hash(data: bytes(challenge: challenge, pairRequestHash: pairRequestHash)))
    }
}
