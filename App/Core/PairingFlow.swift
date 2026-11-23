import Foundation
import LastideKit
import Observation

/// Where the phone stands in one pairing (protocol section 4.3, the phone's steps).
enum PairingStep: Equatable, Sendable {
    /// Nothing started. The Settings screen offers "Pair a PC".
    case idle
    /// The disclosure waits for the person's agreement (step 4).
    case disclosure
    /// The camera or the paste field waits for a pairing code (step 5).
    case scan
    /// The pairing socket opens and waits for `welcome` (step 7).
    case connecting
    /// The pair request left, or the attestation runs, and no code exists yet (step 9).
    case waitingForPC
    /// `pair-received` opened. The person types this code on the PC (step 15).
    case checkCode(String)
    /// `pair-accept` opened (step 21).
    case paired(pcName: String)
    /// The pairing ended without a pairing. The sentence says why.
    case failed(String)
}

/// The phone's side of one pairing, from the disclosure to "Paired with" (protocol sections 4.3, 4.6 and 9.6).
///
/// While the relay runs phase 7, its `welcome` carries an attest challenge. The phone then attests a new App Attest key
/// for this pairing, sends `attest`, and sends the pair request only after the relay's `ok` (design section 7.1).
@MainActor
@Observable
final class PairingFlow {
    private(set) var step: PairingStep = .idle

    @ObservationIgnored private let facts: DeviceFacts
    @ObservationIgnored private let sockets: RelaySocketFactory
    @ObservationIgnored private let attester: AppAttester
    @ObservationIgnored private let now: () -> Int
    @ObservationIgnored private let consentAcceptedAt: () -> Int?
    @ObservationIgnored private let onAccepted: (PairingResult, String?) -> Void
    @ObservationIgnored private let onError: (String) -> Void
    @ObservationIgnored private var payload: QRPayload?
    @ObservationIgnored private var pairing: PhonePairing?
    @ObservationIgnored private var socket: RelaySocket?
    @ObservationIgnored private let keepAlive = KeepAlive()
    /// The attestation of this pairing: its work, its key id, and the `rid` of the `attest` frame that waits for `ok`.
    @ObservationIgnored private var attestTask: Task<Void, Never>?
    @ObservationIgnored private var attestKeyId: String?
    @ObservationIgnored private var attestRid: String?
    @ObservationIgnored private var attestTimeout: Task<Void, Never>?

    /// The phone retries `attestKey` on `serverUnavailable` every 3 s for 30 s, and waits 10 s for the relay's `ok`.
    static let attestRetryNs: UInt64 = 3_000_000_000
    static let attestRetryLimitNs: UInt64 = 30_000_000_000
    static let attestAnswerNs: UInt64 = 10_000_000_000

    /// `consentAcceptedAt` reads the stored agreement time. `onAccepted` stores the result with the App Attest key id,
    /// and connects as `phone`. `onError` records a dropped frame or a refusal for the diagnostics block.
    init(facts: DeviceFacts, sockets: RelaySocketFactory, attester: AppAttester, now: @escaping () -> Int,
         consentAcceptedAt: @escaping () -> Int?, onAccepted: @escaping (PairingResult, String?) -> Void,
         onError: @escaping (String) -> Void) {
        self.facts = facts
        self.sockets = sockets
        self.attester = attester
        self.now = now
        self.consentAcceptedAt = consentAcceptedAt
        self.onAccepted = onAccepted
        self.onError = onError
    }

    /// A flow fixed at one step, for the screenshots of the Pair and Settings screen.
    static func fixed(at step: PairingStep, facts: DeviceFacts, sockets: RelaySocketFactory) -> PairingFlow {
        let flow = PairingFlow(facts: facts, sockets: sockets, attester: UnsupportedAttester(), now: currentTimeMs,
                               consentAcceptedAt: { nil },
                               onAccepted: { _, _ in preconditionFailure("a fixed flow does not pair") }, onError: { _ in })
        flow.step = step
        return flow
    }

    /// "Pair a PC": the disclosure comes first until the person agrees once.
    func begin() {
        cancel()
        step = consentAcceptedAt() == nil ? .disclosure : .scan
    }

    /// The person agreed to the disclosure. The caller stored the time before this call.
    func disclosureAccepted() {
        precondition(consentAcceptedAt() != nil, "store the agreement time before moving on")
        step = .scan
    }

    /// A scanned or pasted string. Parses it and opens the pairing socket (steps 5 and 7).
    func submit(code text: String) {
        guard case .scan = step else { return }
        let payload: QRPayload
        do {
            payload = try QRPayload.parse(text.trimmingCharacters(in: .whitespacesAndNewlines), relayOrigins: facts.relayOrigins)
        } catch let error as QRError {
            step = .failed(error.displayText)
            return
        } catch {
            preconditionFailure("QRPayload.parse throws only QRError")
        }
        self.payload = payload
        step = .connecting
        let socket = sockets.open(url: payload.socketURL) { [weak self] event in self?.handle(event) }
        self.socket = socket
        socket.send(text: ControlFrame.helloPairing(ticket: payload.ticket))
        keepAlive.start(sendPing: { [weak self] in self?.socket?.send(text: ControlFrame.ping) },
                        onTimeout: { [weak self] in self?.end(.failed(AppText.pairingTimedOut)) })
    }

    /// Stops the pairing and closes its socket.
    func cancel() {
        stopAttesting()
        attestKeyId = nil
        keepAlive.stop()
        socket?.close()
        socket = nil
        pairing = nil
        payload = nil
        step = .idle
    }

    private func handle(_ event: SocketEvent) {
        switch event {
        case .text(let text):
            handle(text: text)
        case .binary(let frame):
            handle(frame: frame)
        case .closed(let code, let reason):
            stopAttesting()
            keepAlive.stop()
            socket = nil
            switch step {
            case .paired, .failed, .idle:
                return
            default:
                break
            }
            if let code { onError("pairing socket closed with \(code)") } else { onError("pairing socket failed: \(reason)") }
            step = .failed(Self.sentence(forClose: code))
        }
    }

    private func handle(text: String) {
        let frame: RelayFrame
        do { frame = try ControlFrame.parse(text) } catch {
            onError("relay frame refused: \(error)")
            return
        }
        switch frame {
        case .pong:
            keepAlive.pongArrived()
        case .welcome(let welcome):
            guard case .connecting = step, let payload else { return }
            let pairing: PhonePairing
            do {
                guard let acceptedAt = consentAcceptedAt() else { preconditionFailure("pairing started without agreement") }
                pairing = try PhonePairing(payload: payload, deviceName: facts.deviceName, model: facts.model, app: facts.app,
                                           consentAcceptedAt: acceptedAt, now: now())
            } catch {
                onError("pair request not built: \(error)")
                end(.failed("This phone could not build its pairing request."))
                return
            }
            self.pairing = pairing
            attestKeyId = nil
            step = .waitingForPC
            // Protocol 9.6: without a challenge, or where App Attest reports no support, the phone sends at once.
            if let challenge = welcome.attestChallenge, attester.isSupported {
                let h1 = pairing.h1
                attestTask = Task { @MainActor [weak self] in
                    await self?.attest(challenge: challenge, h1: h1)
                }
            } else {
                socket?.send(binary: pairing.pairRequestEnvelope)
            }
        case .ok(let rid):
            guard rid == attestRid, let pairing else { return }
            attestRid = nil
            attestTimeout?.cancel()
            attestTimeout = nil
            socket?.send(binary: pairing.pairRequestEnvelope)
        case .refused(let rid, let code):
            guard let rid, rid == attestRid else { return }
            onError("attest refused: \(code)")
            end(.failed(RelayCloseCode.attestationRefused.displayText(pairing: true) ?? AppText.attestFailed))
        default:
            return
        }
    }

    /// Steps 3 to 8 of design section 7.1: a new key, its attestation over the client data hash, and the `attest`
    /// frame. On `serverUnavailable` the phone tries again with the same key every 3 s for 30 s.
    private func attest(challenge: Data, h1: Data) async {
        let hash = AttestClientData.hash(challenge: challenge, pairRequestHash: h1)
        let keyId: String
        do {
            keyId = try await attester.generateKey()
        } catch {
            guard !Task.isCancelled else { return }
            onError("App Attest key not made: \(error)")
            end(.failed(AppText.attestFailed))
            return
        }
        let started = DispatchTime.now().uptimeNanoseconds
        var attestation: Data?
        while attestation == nil {
            guard !Task.isCancelled, case .waitingForPC = step else { return }
            do {
                attestation = try await attester.attestKey(keyId, clientDataHash: hash)
            } catch {
                guard !Task.isCancelled else { return }
                let elapsed = DispatchTime.now().uptimeNanoseconds - started
                if attester.isServerUnavailable(error), elapsed + Self.attestRetryNs < Self.attestRetryLimitNs {
                    try? await Task.sleep(nanoseconds: Self.attestRetryNs)
                    continue
                }
                onError("App Attest refused: \(error)")
                end(.failed(AppText.attestFailed))
                return
            }
        }
        guard !Task.isCancelled, case .waitingForPC = step, let attestation else { return }
        attestKeyId = keyId
        attestRid = "a1"
        socket?.send(text: ControlFrame.attest(rid: "a1", keyId: keyId, attestation: attestation, pairRequestHash: h1))
        attestTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.attestAnswerNs)
            guard !Task.isCancelled, let self, self.attestRid != nil else { return }
            self.onError("the relay did not answer attest within 10 s")
            self.end(.failed(AppText.unreachable))
        }
    }

    /// Stops the attestation's work and timer. The key id stays for `onAccepted`.
    private func stopAttesting() {
        attestTask?.cancel()
        attestTask = nil
        attestTimeout?.cancel()
        attestTimeout = nil
        attestRid = nil
    }

    private func handle(frame: Data) {
        guard var pairing else { return }
        do {
            let event = try pairing.receive(frame, now: now())
            self.pairing = pairing
            switch event {
            case .checkCode(let code):
                step = .checkCode(code.display)
            case .accepted(let result):
                keepAlive.stop()
                step = .paired(pcName: result.record.pcName)
                onAccepted(result, attestKeyId)
                attestKeyId = nil
            case .refused(let reason):
                keepAlive.stop()
                step = .failed(reason.displayText)
            }
        } catch {
            onError("pairing frame dropped: \(error)")
        }
    }

    private func end(_ step: PairingStep) {
        stopAttesting()
        keepAlive.stop()
        socket?.close()
        socket = nil
        self.step = step
    }

    /// The sentence for a pairing socket that closed before the pairing ended (protocol Table 17).
    static func sentence(forClose code: Int?) -> String {
        guard let code else { return AppText.unreachable }
        if let close = RelayCloseCode(rawValue: code), let text = close.displayText(pairing: true) { return text }
        if code == RelayCloseCode.timeout.rawValue { return AppText.pairingTimedOut }
        return "The relay closed the pairing with code \(code). Scan a new code."
    }
}
