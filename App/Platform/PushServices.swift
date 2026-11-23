import DeviceCheck
import Foundation
import LastideKit
import UIKit
import UserNotifications
import WidgetKit

// The system services of phase 7 behind small protocols, so the hosted tests hand the model fakes.

/// Posts one `/frames` request (protocol 6.14).
@MainActor
protocol FramesPoster: AnyObject {
    func post(_ request: FramesRequest) async -> FramesAnswer
}

/// `/frames` over `URLSession`, with the 20 s limit of design 6.5, step 9.
@MainActor
final class URLSessionFramesPoster: FramesPoster {
    func post(_ request: FramesRequest) async -> FramesAnswer { await Self.send(request) }

    nonisolated private static func send(_ request: FramesRequest) async -> FramesAnswer {
        var urlRequest = URLRequest(url: request.url, cachePolicy: .reloadIgnoringLocalCacheData,
                                    timeoutInterval: FramesRequest.timeoutSeconds)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(request.device, forHTTPHeaderField: FramesRequest.deviceHeader)
        urlRequest.setValue(FramesRequest.contentType, forHTTPHeaderField: "Content-Type")
        do {
            let (data, response) = try await URLSession.shared.upload(for: urlRequest, from: request.body)
            guard let http = response as? HTTPURLResponse else { return .refused("no HTTP answer") }
            return FramesAnswer(status: http.statusCode, body: data)
        } catch {
            return .refused("no answer: \(error.localizedDescription)")
        }
    }
}

/// Whether the phone is unlocked when a lock-screen action arrives (design 6.5, step 1). `authenticationRequired` asks
/// iOS for an unlocked device, and a paired Apple Watch can still send an action while the phone stays locked.
@MainActor
protocol DeviceLock: AnyObject {
    /// True while files with `complete` protection open, which iOS allows only while the phone is unlocked.
    var isUnlocked: Bool { get }
}

@MainActor
final class SystemDeviceLock: DeviceLock {
    var isUnlocked: Bool { UIApplication.shared.isProtectedDataAvailable }
}

/// Posts a local notification with the plain category (design 6.5, steps 5 and 10).
@MainActor
protocol LocalNotices: AnyObject {
    func post(_ body: String)
    /// Sets the app icon's badge to the waiting count.
    func setBadge(_ count: Int)
}

@MainActor
final class UserNotificationsPoster: LocalNotices {
    func setBadge(_ count: Int) {
        UNUserNotificationCenter.current().setBadgeCount(count, withCompletionHandler: nil)
    }

    func post(_ body: String) {
        let content = UNMutableNotificationContent()
        content.title = PushText.appName
        content.body = body
        content.categoryIdentifier = PushText.plainCategory
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}

/// The two categories of design Table 15.
enum NotificationCategories {
    static func make() -> Set<UNNotificationCategory> {
        let approve = UNNotificationAction(identifier: PushText.approveAction, title: "Approve",
                                           options: [.authenticationRequired])
        let delete = UNNotificationAction(identifier: PushText.deleteAction, title: "Delete",
                                          options: [.destructive, .authenticationRequired])
        let open = UNNotificationAction(identifier: PushText.openAction, title: "Open", options: [.foreground])
        let rule = UNNotificationCategory(identifier: PushText.ruleCategory, actions: [approve, delete, open],
                                          intentIdentifiers: [],
                                          hiddenPreviewsBodyPlaceholder: PushText.hiddenPreviewsPlaceholder, options: [])
        let plain = UNNotificationCategory(identifier: PushText.plainCategory, actions: [open], intentIdentifiers: [],
                                           hiddenPreviewsBodyPlaceholder: PushText.hiddenPreviewsPlaceholder, options: [])
        return [rule, plain]
    }
}

/// What iOS allows the app to show, as the Settings screen names it (design 6.8).
enum NotificationPermission: Equatable, Sendable {
    /// iOS allows the app's alerts: "On".
    case on
    /// The person turned the app's notifications off: "Off in iOS Settings".
    case off
    /// iOS never asked: "Not asked yet".
    case notAsked
    /// The app has not read the setting yet.
    case unknown

    var label: String {
        switch self {
        case .on: return "On"
        case .off: return "Off in iOS Settings"
        case .notAsked: return "Not asked yet"
        case .unknown: return "Checking"
        }
    }
}

/// Reads and asks for the notification permission.
@MainActor
protocol NotificationAccess: AnyObject {
    /// The permission and whether lock-screen previews show.
    func read() async -> (NotificationPermission, PreviewSetting)
    /// Asks iOS for alerts, badges and sounds. Returns the permission after the answer.
    func request() async -> NotificationPermission
}

@MainActor
final class UserNotificationsAccess: NotificationAccess {
    func read() async -> (NotificationPermission, PreviewSetting) { await Self.readSettings() }

    func request() async -> NotificationPermission {
        _ = await Self.requestAuthorization()
        return await Self.readSettings().0
    }

    nonisolated static func readSettings() async -> (NotificationPermission, PreviewSetting) {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                let permission: NotificationPermission
                switch settings.authorizationStatus {
                case .authorized: permission = .on
                case .notDetermined: permission = .notAsked
                default: permission = .off
                }
                let previews: PreviewSetting
                switch settings.showPreviewsSetting {
                case .always: previews = .always
                case .whenAuthenticated: previews = .whenAuthenticated
                default: previews = .never
                }
                continuation.resume(returning: (permission, previews))
            }
        }
    }

    nonisolated private static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }
}

/// App Attest on a new pairing (design section 7.1).
@MainActor
protocol AppAttester: AnyObject {
    var isSupported: Bool { get }
    func generateKey() async throws -> String
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data
    /// True for `DCError.serverUnavailable`, which Apple asks the app to retry with the same key.
    func isServerUnavailable(_ error: Error) -> Bool
}

@MainActor
final class DeviceCheckAttester: AppAttester {
    struct NoResult: Error {}

    var isSupported: Bool { DCAppAttestService.shared.isSupported }

    func generateKey() async throws -> String { try await Self.generate() }

    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
        try await Self.attest(keyId, clientDataHash)
    }

    func isServerUnavailable(_ error: Error) -> Bool { (error as? DCError)?.code == .serverUnavailable }

    nonisolated private static func generate() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DCAppAttestService.shared.generateKey { keyId, error in
                if let keyId { continuation.resume(returning: keyId) } else { continuation.resume(throwing: error ?? NoResult()) }
            }
        }
    }

    nonisolated private static func attest(_ keyId: String, _ hash: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DCAppAttestService.shared.attestKey(keyId, clientDataHash: hash) { attestation, error in
                if let attestation {
                    continuation.resume(returning: attestation)
                } else {
                    continuation.resume(throwing: error ?? NoResult())
                }
            }
        }
    }
}

/// An attester for the simulator and the screenshots: App Attest reports no support there.
@MainActor
final class UnsupportedAttester: AppAttester {
    struct Unsupported: Error {}
    var isSupported: Bool { false }
    func generateKey() async throws -> String { throw Unsupported() }
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data { throw Unsupported() }
    func isServerUnavailable(_ error: Error) -> Bool { false }
}

/// The widget's push token and the number of placed widgets (design 6.3, "The widget token").
@MainActor
protocol WidgetPushSource: AnyObject {
    /// The token in raw bytes, or nil while no widget is placed, and the number of placed widgets.
    func current(group: GroupFiles?) async -> (token: Data?, widgets: Int)
    func reloadTimelines()
}

@MainActor
final class WidgetKitPushSource: WidgetPushSource {
    func current(group: GroupFiles?) async -> (token: Data?, widgets: Int) {
        let (pushInfoToken, widgets) = await Self.read()
        if widgets == 0 { return (nil, 0) }
        if let pushInfoToken { return (pushInfoToken, widgets) }
        // `pushTokenDidChange` writes widget-push.json, and a forum report says `currentPushInfo` can be empty.
        let stored = (try? group?.loadWidgetPush())?.token
        return (stored.flatMap { Data(hexToken: $0) }, widgets)
    }

    func reloadTimelines() { WidgetCenter.shared.reloadAllTimelines() }

    nonisolated private static func read() async -> (Data?, Int) {
        let info = await WidgetCenter.shared.currentPushInfo
        let widgets = (try? await WidgetCenter.shared.currentConfigurations())?.count ?? 0
        return (info?.token, widgets)
    }
}
