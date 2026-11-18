import Foundation
import UIKit

extension DeviceFacts {
    /// This phone's name and model, and the build's version and relay origins.
    @MainActor
    static func current() -> DeviceFacts {
        var info = utsname()
        uname(&info)
        let model = withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        let values = bundleValues(.main)
        return DeviceFacts(deviceName: UIDevice.current.name, model: model, app: values.app, relayOrigins: values.relayOrigins)
    }
}

/// Extra time after the app leaves the screen, to send the outbox (protocol section 6.8).
@MainActor
final class BackgroundFlush {
    private var taskID: UIBackgroundTaskIdentifier = .invalid

    /// Runs `work` inside a background task. When iOS refuses the task, `work` runs until iOS suspends the app.
    /// Decisions that did not leave then stay in the outbox as "Not sent yet".
    func run(_ work: @escaping @MainActor @Sendable () async -> Void) {
        finish()
        taskID = UIApplication.shared.beginBackgroundTask(withName: "Send decisions") { [weak self] in
            MainActor.assumeIsolated { self?.finish() }
        }
        Task { @MainActor [weak self] in
            await work()
            self?.finish()
        }
    }

    private func finish() {
        guard taskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(taskID)
        taskID = .invalid
    }
}
