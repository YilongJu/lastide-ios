import Foundation

/// One `POST /api/relay/<pairing id>/frames` request from a notification action (protocol 6.14).
public struct FramesRequest: Hashable, Sendable {
    /// The header that names the phone's device id.
    public static let deviceHeader = "Lastide-Device"
    /// The request's content type.
    public static let contentType = "application/octet-stream"
    /// The app waits this long for the answer (design 6.5, step 9).
    public static let timeoutSeconds: Double = 20

    /// `https://<relay origin>/api/relay/<pairing id>/frames`.
    public let url: URL
    /// The value of `Lastide-Device`: the phone's device id in base64url, 22 characters.
    public let device: String
    /// The 32-byte phone token, then the envelope.
    public let body: Data

    /// Builds the request for one sealed envelope of the phone's pairing with that PC.
    public init(record: PairingRecord, token: Data, envelope: Data) {
        precondition(token.count == 32, "a phone token holds 32 bytes")
        precondition((LastideProtocol.smallestEnvelope...LastideProtocol.largestEnvelope).contains(envelope.count),
                     "an envelope holds 92 to 262,144 bytes")
        guard let url = URL(string: record.relayOrigin + "/api/relay/" + record.pairingId.base64url + "/frames") else {
            preconditionFailure("a stored relay origin forms a URL")
        }
        self.url = url
        device = record.phoneId.base64url
        body = token + envelope
    }
}

/// What the app does with the relay's answer to `/frames` (protocol 6.14).
public enum FramesAnswer: Hashable, Sendable {
    /// 202: the envelope entered the mailbox. The app marks the decision stored.
    case stored(seq: UInt64)
    /// 410: the room was deleted. The app offers to remove the PC.
    case roomGone
    /// 403 `notAttested`: the app offers to pair the phone again.
    case notAttested
    /// Any other answer: the decision waits for the next connection. The text is the relay's error code, or
    /// "status <n>" when the answer carried none.
    case refused(String)

    /// Reads one answer.
    public init(status: Int, body: Data) {
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        if status == 202, object?["stored"] as? Bool == true, let seq = object?["seq"] as? Int, seq >= 1,
           seq <= LastideProtocol.largestInteger {
            self = .stored(seq: UInt64(seq))
            return
        }
        guard status != 202, let error = object?["error"] as? String else {
            self = .refused("status \(status)")
            return
        }
        switch (status, error) {
        case (410, "roomGone"): self = .roomGone
        case (403, "notAttested"): self = .notAttested
        default: self = .refused(error)
        }
    }

    /// True for a 202.
    public var isStored: Bool {
        if case .stored = self { return true }
        return false
    }
}
