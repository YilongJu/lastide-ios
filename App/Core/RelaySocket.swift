import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LastideKit

/// One event from a relay socket.
enum SocketEvent: Sendable, Equatable {
    case text(String)
    case binary(Data)
    /// The socket ended. `code` is the WebSocket close code, or nil when the connection failed without one.
    case closed(code: Int?, reason: String)
}

/// One WebSocket to the relay, opened with the subprotocol `lastide-relay.1` (protocol section 6.2).
@MainActor
protocol RelaySocket: AnyObject {
    /// Sends one text frame. Frames leave in the order of the calls.
    func send(text: String)
    /// Sends one binary frame.
    func send(binary: Data)
    /// Closes the socket with code 1000, the only code a device sends. The socket reports no event after this call.
    func close()
}

/// Opens relay sockets. The app uses `URLSessionSocketFactory`, and the checks use a fake.
@MainActor
protocol RelaySocketFactory: AnyObject {
    func open(url: URL, onEvent: @escaping @MainActor (SocketEvent) -> Void) -> RelaySocket
}

/// A relay socket on `URLSessionWebSocketTask` (protocol section 6.2, step 1).
@MainActor
final class URLSessionRelaySocket: RelaySocket {
    private let task: URLSessionWebSocketTask
    private let onEvent: @MainActor (SocketEvent) -> Void
    private var ended = false

    init(session: URLSession, url: URL, onEvent: @escaping @MainActor (SocketEvent) -> Void) {
        task = session.webSocketTask(with: url, protocols: [LastideProtocol.webSocketSubprotocol])
        task.maximumMessageSize = LastideProtocol.largestEnvelope
        self.onEvent = onEvent
        task.resume()
        receiveNext()
    }

    func send(text: String) { send(.string(text)) }

    func send(binary: Data) { send(.data(binary)) }

    func close() {
        guard !ended else { return }
        ended = true
        task.cancel(with: .normalClosure, reason: nil)
    }

    private func send(_ message: URLSessionWebSocketTask.Message) {
        guard !ended else { return }
        task.send(message) { [weak self] error in
            guard let error else { return }
            let text = error.localizedDescription
            Task { @MainActor in self?.end(reason: "send failed: \(text)") }
        }
    }

    private func receiveNext() {
        task.receive { [weak self] result in
            switch result {
            case .success(.string(let text)):
                Task { @MainActor in self?.deliver(.text(text)) }
            case .success(.data(let data)):
                Task { @MainActor in self?.deliver(.binary(data)) }
            case .success:
                Task { @MainActor in self?.end(reason: "an unknown frame type") }
            case .failure(let error):
                let text = error.localizedDescription
                Task { @MainActor in self?.end(reason: text) }
            }
        }
    }

    private func deliver(_ event: SocketEvent) {
        guard !ended else { return }
        onEvent(event)
        guard !ended else { return }
        receiveNext()
    }

    private func end(reason: String) {
        guard !ended else { return }
        ended = true
        let raw = task.closeCode.rawValue
        task.cancel()
        onEvent(.closed(code: raw == 0 ? nil : raw, reason: reason))
    }
}

/// Opens `URLSessionRelaySocket`s on one shared session.
@MainActor
final class URLSessionSocketFactory: RelaySocketFactory {
    private let session = URLSession(configuration: .default)

    func open(url: URL, onEvent: @escaping @MainActor (SocketEvent) -> Void) -> RelaySocket {
        URLSessionRelaySocket(session: session, url: url, onEvent: onEvent)
    }
}
