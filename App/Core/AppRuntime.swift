import Foundation
import LastideKit
import UIKit
import UserNotifications

/// What the launch path needs from the system (design sections 6.2, 6.3 and 6.6). The hosted tests replace each part.
@MainActor
struct LaunchEnvironment {
    /// The files in the app's own container.
    var files: () throws -> AppFiles
    /// Where builds before phase 7 kept `pairings.json`.
    var oldPairingsURL: URL
    /// The App Group files, or nil when iOS gives no container.
    var group: () -> GroupFiles?
    /// The shared Keychain group `<team>.dev.lastide.app.shared`.
    var keychainGroup: () throws -> String
    /// The Keychain store in that group.
    var secrets: (String) -> SecretStore
    /// Moves the items of the service `lastide.pairing` into that group.
    var moveKeychain: (String) throws -> KeychainMove.Report
    /// True while files with `complete` protection open, which means the phone is unlocked.
    var protectedDataAvailable: () -> Bool
    /// Calls `registerForRemoteNotifications`.
    var registerForPushes: () -> Void

    /// The real system.
    static func live() -> LaunchEnvironment {
        let appSupport = URL.applicationSupportDirectory.appendingPathComponent("Lastide", isDirectory: true)
        return LaunchEnvironment(
            files: { try FileStorage(directory: appSupport) },
            oldPairingsURL: appSupport.appendingPathComponent("pairings.json"),
            group: { try? GroupFiles.shared() },
            keychainGroup: { try KeychainGroup.shared() },
            secrets: { KeychainStore(accessGroup: $0) },
            moveKeychain: { try KeychainMove.run(service: KeychainStore.service, into: $0) },
            protectedDataAvailable: { UIApplication.shared.isProtectedDataAvailable },
            registerForPushes: { UIApplication.shared.registerForRemoteNotifications() })
    }
}

/// The one runtime of the app: the one model, the launch path, background pushes and notification actions.
///
/// `LastideApp` and the delegate both reach the model through `AppRuntime.shared`, so a lock-screen action and the
/// socket take `seq` from one counter (design section 6.3).
@MainActor
final class AppRuntime {
    static let shared = makeShared()

    /// True inside the host of the hosted tests. The tests reach the Keychain and the App Group themselves.
    static var isHostedTest: Bool { ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil }

    let screenshot: ScreenshotLaunch?
    let model: AppModel
    /// The bundled changelog and the sheet shown once after an update.
    let whatsNew: WhatsNew
    private let environment: LaunchEnvironment?
    /// The stores once the moves ended. The model loads them when the phone is unlocked.
    private(set) var stores: LiveStores?
    private var unlockObserver: NSObjectProtocol?

    /// A runtime on `environment`. Without one, as in a screenshot run or the test host, it reads nothing.
    init(model: AppModel, screenshot: ScreenshotLaunch?, environment: LaunchEnvironment?) {
        self.model = model
        self.screenshot = screenshot
        self.environment = environment
        let build = model.facts.app.build
        if let screenshot {
            whatsNew = .screenshot(screenshot.screen)
        } else if Self.isHostedTest {
            whatsNew = .quiet(installedBuild: build)
        } else {
            whatsNew = .live(installedBuild: build)
        }
    }

    private static func makeShared() -> AppRuntime {
        let facts = DeviceFacts.current()
        do {
            if let screenshot = ScreenshotLaunch.fromArguments() {
                return AppRuntime(model: try ScreenshotStaging.model(for: screenshot.screen, facts: facts),
                                  screenshot: screenshot, environment: nil)
            }
            let model = try AppModel(facts: facts, services: .live(), now: currentTimeMs)
            return AppRuntime(model: model, screenshot: nil, environment: isHostedTest ? nil : .live())
        } catch {
            fatalError("Lastide could not start: \(error)")
        }
    }

    // MARK: Launch

    /// Runs once from `application(_:didFinishLaunchingWithOptions:)`: the moves, the model's load when the phone is
    /// unlocked, then the push registration (design sections 6.2 and 6.3).
    func start() {
        guard let environment else { return }
        prepare()
        guard model.launchError == nil else { return }
        environment.registerForPushes()
    }

    /// The moves of design section 6.2, then the model's load. A step that cannot run on a locked phone waits for
    /// `protectedDataDidBecomeAvailableNotification`. A missing App Group container stops the app before it reads
    /// another file or deletes a Keychain item.
    func prepare() {
        guard let environment, model.launchError == nil else { return }
        if stores == nil {
            guard let group = environment.group() else {
                model.launchError = AppText.storageError
                model.noteProblem(GroupFiles.MissingContainer().description)
                return
            }
            do {
                let files = try environment.files()
                let keychainGroup = try environment.keychainGroup()
                let report = try environment.moveKeychain(keychainGroup)
                let movedFile = try StorageMove.movePairings(from: environment.oldPairingsURL, to: group)
                model.noteLaunchMoves("moved \(report.moved) Keychain items, removed \(report.duplicatesRemoved) duplicates, "
                                      + (movedFile ? "moved pairings.json" : "pairings.json already in the App Group"))
                stores = LiveStores(files: files, group: group, secrets: environment.secrets(keychainGroup),
                                    oldPairingsURL: environment.oldPairingsURL)
            } catch {
                model.noteProblem("the moves did not run: \(error)")
                if environment.protectedDataAvailable() {
                    // The phone is unlocked, so the failure is not the lock. The app stops with the error.
                    model.launchError = "Lastide could not move its stored pairings."
                } else {
                    waitForUnlock()
                }
                return
            }
        }
        guard let stores, !model.isLoaded else { return }
        guard environment.protectedDataAvailable() else {
            waitForUnlock()
            return
        }
        do {
            try model.load(stores)
        } catch {
            model.noteProblem("the files did not open: \(error)")
            waitForUnlock()
        }
    }

    private func waitForUnlock() {
        guard unlockObserver == nil else { return }
        unlockObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.unlocked() }
        }
    }

    /// The phone unlocked: run what waited.
    func unlocked() {
        if let unlockObserver { NotificationCenter.default.removeObserver(unlockObserver) }
        unlockObserver = nil
        prepare()
    }

    // MARK: Background pushes

    /// A count update in slot 1 (design section 6.6). It needs no model: the handler reads `pairings.json` and
    /// `counts/` from the App Group and the key from the Keychain, so it runs on a locked phone after the first unlock.
    func handleBackgroundPush(_ payload: [AnyHashable: Any]) -> UIBackgroundFetchResult {
        guard let environment, let group = environment.group() else { return .failed }
        do {
            let secrets = environment.secrets(try environment.keychainGroup())
            guard try CountUpdates.handle(payload: payload, group: group, secrets: secrets, now: currentTimeMs()) else {
                return .noData
            }
            model.waitingCountsChanged(group: group)
            return .newData
        } catch {
            model.noteProblem("count update not stored: \(error)")
            return .failed
        }
    }

    // MARK: Notification actions

    /// Approve or Delete from a notification (design section 6.5). `envelope` is the notification's `lastide.e`.
    func handleNotificationAction(identifier: String, envelope: Data?, shown: NotificationText) async {
        let action: DecisionAction
        switch identifier {
        case PushText.approveAction: action = .approve
        case PushText.deleteAction: action = .delete
        default: return
        }
        let task = BackgroundTask(name: "lastide.notification-action")
        if !model.isLoaded { prepare() }
        _ = await model.actOnNotice(envelope: envelope, action: action, shown: shown)
        task.end()
    }
}

/// Stores a newer count from a count update (design section 6.6).
enum CountUpdates {
    /// Opens a slot 1 envelope and writes `counts/<pairing id>.json` when its store version is newer than the stored
    /// count. Returns true when it wrote one.
    static func handle(payload: [AnyHashable: Any], group: GroupFiles, secrets: SecretStore, now: Int) throws -> Bool {
        let envelope = try PushOpener.envelope(from: payload)
        let opened = try PushOpener.open(envelope, slot: PushOpener.countUpdateSlot, records: try group.loadRecords(),
                                         phoneKey: { try secrets.load(account: SecretAccount.key($0.pairingId)) })
        guard let update = opened.countUpdate else { throw PushFailure.badMessage }
        let id = opened.record.pairingId
        if let current = WaitingCount.newest(push: try group.loadPush(id), count: try group.loadCount(id)),
           update.storeVersion <= current.storeVersion {
            return false
        }
        try group.saveCount(CountState(storeVersion: update.storeVersion, queueCount: update.queueCount, at: now), id)
        return true
    }
}

/// Extra time in the background for one notification action.
@MainActor
final class BackgroundTask {
    private var id: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
