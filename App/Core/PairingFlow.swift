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
    /// The pair request left, and no code exists yet (step 9).
    case waitingForPC
    /// `pair-received` opened. The person types this code on the PC (step 15).
    case checkCode(String)
    /// `pair-accept` opened (step 21).
    case paired(pcName: String)
    /// The pairing ended without a pairing. The sentence says why.
    case failed(String)
}

/// The phone's side of one pairing, from the disclosure to "Paired with" (protocol sections 4.3 and 4.6).
@MainActor
@Observable
final class PairingFlow {
    private(set) var step: PairingStep = .idle

    @ObservationIgnored private let facts: DeviceFacts
    @ObservationIgnored private let sockets: RelaySocketFactory
    @ObservationIgnored private let now: () -> Int
    @ObservationIgnored private let consentAcceptedAt: () -> Int?
    @ObservationIgnored private let onAccepted: (PairingResult) -> Void
    @ObservationIgnored private let onError: (String) -> Void
    @ObservationIgnored private var payload: QRPayload?
    @ObservationIgnored private var pairing: PhonePairing?
    @ObservationIgnored private var socket: RelaySocket?
    @ObservationIgnored private let keepAlive = KeepAlive()

    /// `consentAcceptedAt` reads the stored agreement time. `onAccepted` stores the result and connects as `phone`.
    /// `onError` records a dropped frame or a refusal for the diagnostics block.
    init(facts: DeviceFacts, sockets: RelaySocketFactory, now: @escaping () -> Int, consentAcceptedAt: @escaping () -> Int?,
         onAccepted: @escaping (PairingResult) -> Void, onError: @escaping (String) -> Void) {
        self.facts = facts
        self.sockets = sockets
        self.now = now
        self.consentAcceptedAt = consentAcceptedAt
        self.onAccepted = onAccepted
        self.onError = onError
    }

    /// A flow fixed at one step, for the screenshots of the Pair and Settings screen.
    static func fixed(at step: PairingStep, facts: DeviceFacts, sockets: RelaySocketFactory) -> PairingFlow {
        let flow = PairingFlow(facts: facts, sockets: sockets, now: currentTimeMs, consentAcceptedAt: { nil },
                               onAccepted: { _ in preconditionFailure("a fixed flow does not pair") }, onError: { _ in })
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
        case .welcome:
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
            socket?.send(binary: pairing.pairRequestEnvelope)
            step = .waitingForPC
        default:
            return
        }
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
                onAccepted(result)
            case .refused(let reason):
                keepAlive.stop()
                step = .failed(reason.displayText)
            }
        } catch {
            onError("pairing frame dropped: \(error)")
        }
    }

    private func end(_ step: PairingStep) {
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
