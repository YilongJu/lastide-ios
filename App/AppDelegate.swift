import LastideKit
import UIKit
import UserNotifications

/// The app delegate of phase 7 (design sections 6.3, 6.5 and 6.6): the launch path, the device token, count updates in
/// the background, and the actions of a notification.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // The test host skips the real launch path, so a hosted test starts with no moves, no registration and no load.
        guard !AppRuntime.isHostedTest else { return true }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories(NotificationCategories.make())
        // A screenshot run has no launch environment, so `start` skips the moves and the registration.
        AppRuntime.shared.start()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        AppRuntime.shared.model.deviceTokenArrived(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        AppRuntime.shared.model.registrationFailed(error.localizedDescription)
    }

    /// A count update in the background. UIKit calls this on the main thread, and the method calls the fetch handler
    /// before it returns, so the handler runs on the main thread with no task between them.
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        completionHandler(AppRuntime.shared.handleBackgroundPush(userInfo))
    }

    /// Approve, Delete or Open from a notification. iOS calls this on a queue of its own, so the method is nonisolated.
    /// It reads the envelope and the shown text here, so only values that may cross to the main actor leave it. Then
    /// it runs the action on the main actor and calls UIKit's handler there, once, after the action ends. UIKit's
    /// handler asserts the main thread. The async form of this method is not used: its generated bridge called the
    /// handler from a Swift concurrency thread, and that assertion stopped the app (TestFlight build 5).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let content = response.notification.request.content
        let shown = NotificationText(title: content.title, subtitle: content.subtitle, body: content.body,
                                     category: content.categoryIdentifier)
        let envelope = try? PushOpener.envelope(from: content.userInfo)
        let identifier = response.actionIdentifier
        let handler = MainThreadHandler(completionHandler)
        Task { @MainActor in
            await self.respond(identifier: identifier, envelope: envelope, shown: shown)
            handler.call()
        }
    }

    /// The hosted tests set this in place of the runtime's handler.
    var notificationAction: (@MainActor (String, Data?, NotificationText) async -> Void)?

    @MainActor
    private func respond(identifier: String, envelope: Data?, shown: NotificationText) async {
        if let notificationAction { return await notificationAction(identifier, envelope, shown) }
        await AppRuntime.shared.handleNotificationAction(identifier: identifier, envelope: envelope, shown: shown)
    }
}

/// UIKit's completion handler for a notification response. The closure is not Sendable, so this box carries it to the
/// main actor, and `call` runs it only there.
private struct MainThreadHandler: @unchecked Sendable {
    private let body: () -> Void

    init(_ body: @escaping () -> Void) { self.body = body }

    @MainActor
    func call() { body() }
}
