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

    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        AppRuntime.shared.handleBackgroundPush(userInfo)
    }

    /// Approve, Delete or Open from a notification. The method reads the envelope and the shown text here, so only
    /// values that may cross to the main actor leave it.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let content = response.notification.request.content
        let shown = NotificationText(title: content.title, subtitle: content.subtitle, body: content.body,
                                     category: content.categoryIdentifier)
        let envelope = try? PushOpener.envelope(from: content.userInfo)
        let identifier = response.actionIdentifier
        await Self.respond(identifier: identifier, envelope: envelope, shown: shown)
    }

    @MainActor
    private static func respond(identifier: String, envelope: Data?, shown: NotificationText) async {
        await AppRuntime.shared.handleNotificationAction(identifier: identifier, envelope: envelope, shown: shown)
    }
}
