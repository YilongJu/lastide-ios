import UserNotifications

/// The notification service extension (design section 6.4).
///
/// Round 3a of the phase 7 design ships this scaffold. It hands each notification on unchanged, so the build proves
/// the target, its entitlements, the export and TestFlight before the push code arrives in round 3b.
final class NotificationService: UNNotificationServiceExtension {
    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        contentHandler(request.content)
    }

    override func serviceExtensionTimeWillExpire() {}
}
