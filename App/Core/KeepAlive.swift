import Foundation

/// The `ping` and `pong` rule of protocol section 6.4. The device sends `ping` every 30 s.
/// When `pong` does not arrive within 10 s, the device gives up on the socket.
@MainActor
final class KeepAlive {
    static let pingIntervalNs: UInt64 = 30_000_000_000
    static let pongWaitNs: UInt64 = 10_000_000_000

    private var loop: Task<Void, Never>?
    private var waitingForPong = false

    /// Starts the loop. `sendPing` sends the text frame `ping`, and `onTimeout` runs once when a `pong` is late.
    func start(sendPing: @escaping @MainActor () -> Void, onTimeout: @escaping @MainActor () -> Void) {
        stop()
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.pingIntervalNs)
                guard !Task.isCancelled, let self else { return }
                self.waitingForPong = true
                sendPing()
                try? await Task.sleep(nanoseconds: Self.pongWaitNs)
                guard !Task.isCancelled else { return }
                if self.waitingForPong {
                    self.stop()
                    onTimeout()
                    return
                }
            }
        }
    }

    /// Records a `pong`.
    func pongArrived() { waitingForPong = false }

    func stop() {
        loop?.cancel()
        loop = nil
        waitingForPong = false
    }
}
