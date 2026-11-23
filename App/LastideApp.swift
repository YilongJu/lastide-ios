import LastideKit
import SwiftUI

/// The screens a screenshot run can open, named by the launch argument `-LastideScreen`.
enum ScreenshotScreen: String, CaseIterable, Sendable {
    case queue, draftDetail, library, ruleDetail, learning, settings
    case pairingDisclosure, pairingScan, pairingWaiting, pairingCode, pairingFailed
    /// A synthetic PC, paired and offline, last seen 2 min ago.
    case settingsPaired
    /// The same PC, with one approval that the relay stored and the PC has not answered yet.
    case queueWaiting
    /// The same PC, with an empty queue.
    case queueEmpty
    /// The same PC's Library while it does not measure violations yet: the counters arrive as null.
    case libraryNotMeasured
    /// The same PC's Learning screen while it does not measure repeat corrections, violations or a daily cap yet.
    case learningNotMeasured
}

/// A screenshot run: `-LastideScreen <screen> -LastideColorScheme light|dark`. The run uses demo data only, and never
/// reads the disk, the Keychain or the network.
struct ScreenshotLaunch: Sendable {
    let screen: ScreenshotScreen
    let dark: Bool

    static func fromArguments() -> ScreenshotLaunch? {
        let defaults = UserDefaults.standard
        guard let name = defaults.string(forKey: "LastideScreen") else { return nil }
        guard let screen = ScreenshotScreen(rawValue: name) else { preconditionFailure("unknown -LastideScreen \(name)") }
        switch defaults.string(forKey: "LastideColorScheme") {
        case "light": return ScreenshotLaunch(screen: screen, dark: false)
        case "dark": return ScreenshotLaunch(screen: screen, dark: true)
        default: preconditionFailure("a screenshot run needs -LastideColorScheme light or dark")
        }
    }
}

@main
struct LastideApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: AppModel
    private let screenshot: ScreenshotLaunch?
    private let background = BackgroundFlush()

    init() {
        let facts = DeviceFacts.current()
        let screenshot = ScreenshotLaunch.fromArguments()
        self.screenshot = screenshot
        do {
            if let screenshot {
                let model = try AppModel(demoWith: facts, sockets: URLSessionSocketFactory())
                switch screenshot.screen {
                case .pairingDisclosure: model.showPairingStep(.disclosure)
                case .pairingScan: model.showPairingStep(.scan)
                case .pairingWaiting: model.showPairingStep(.waitingForPC)
                // The check code of the Lastide test vector (protocol section 10.3).
                case .pairingCode: model.showPairingStep(.checkCode("714 390"))
                case .pairingFailed: model.showPairingStep(.failed(AppText.unreachable))
                case .settingsPaired:
                    model.showForScreenshot(records: [try ScreenshotStaging.record()], store: try ScreenshotStaging.store(queue: true))
                case .queueWaiting:
                    model.showForScreenshot(records: [try ScreenshotStaging.record()],
                                            store: try ScreenshotStaging.store(queue: true, waitingApproval: true))
                case .queueEmpty:
                    model.showForScreenshot(records: [try ScreenshotStaging.record()], store: try ScreenshotStaging.store(queue: false))
                case .libraryNotMeasured, .learningNotMeasured:
                    model.showForScreenshot(records: [try ScreenshotStaging.record()],
                                            store: try ScreenshotStaging.store(queue: true, measured: false))
                case .queue, .draftDetail, .library, .ruleDetail, .learning, .settings: break
                }
                _model = State(initialValue: model)
            } else if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
                // The host of the hosted tests: the tests reach the Keychain and the App Group themselves, so the
                // app reads no file and no Keychain item of its own.
                _model = State(initialValue: try AppModel(demoWith: facts, sockets: URLSessionSocketFactory()))
            } else {
                _model = State(initialValue: try AppModel(facts: facts, storage: FileStorage.appSupport(),
                                                          secrets: KeychainStore(), sockets: URLSessionSocketFactory(),
                                                          now: currentTimeMs))
            }
        } catch {
            fatalError("Lastide could not start: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model, screenshot: screenshot?.screen)
                .preferredColorScheme(screenshot.map { $0.dark ? .dark : .light })
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            guard screenshot == nil else { return }
            switch phase {
            case .active:
                model.cameToScreen()
            case .background:
                let model = model
                background.run { await model.leftScreen() }
            default:
                break
            }
        }
    }
}

/// Synthetic pairings and stores for the screenshots of a paired phone. Every value is made up.
enum ScreenshotStaging {
    /// A PC named WORKSTATION-A on the placeholder relay origin, paired a day ago and last seen 2 min ago.
    static func record() throws -> PairingRecord {
        let now = currentTimeMs()
        let json: [String: Any] = [
            "pairingId": Base64URL.encode(Data((0..<16).map { UInt8($0) })),
            "relayOrigin": "https://relay.example",
            "pcKey": Base64URL.encode(Data((32..<64).map { UInt8($0) })),
            "pcName": "WORKSTATION-A",
            "pcSchema": LastideProtocol.schemaRevision,
            "phoneId": Base64URL.encode(Data((16..<32).map { UInt8($0) })),
            "pairedAt": now - 86_400_000,
            "pcLastSeenAt": now - 120_000,
            "lastSentSeq": 0,
            "lastRecvSeq": 0,
            "features": ["mailbox"],
        ]
        return try JSONDecoder().decode(PairingRecord.self, from: JSONSerialization.data(withJSONObject: json))
    }

    /// A paired store drawn from the demo fixtures. Without `queue` it holds no queue snapshot, so the queue is empty.
    /// `waitingApproval` approves the first draft the phone may act on, and marks the envelope stored by the relay.
    /// Without `measured`, every count that the PC does not measure yet arrives as null (protocol 7.3).
    static func store(queue: Bool, waitingApproval: Bool = false, measured: Bool = true) throws -> ReviewStore {
        let fixtures = try DemoFixtures.load()
        var library = fixtures.library
        var counts = fixtures.counts
        if !measured {
            for index in library.rules.indices {
                library.rules[index].violationsSinceApproval = nil
                library.rules[index].violationsLast30Days = nil
            }
            counts.repeatCorrectionsThisWeek = nil
            counts.repeatCorrectionsLastWeek = nil
            counts.violationsThisWeek = nil
            counts.draftCap = nil
            counts.weeks = []
        }
        var store = ReviewStore(cache: ReviewCache(), outbox: [])
        if queue { store.apply(.queue(fixtures.queue)) }
        store.apply(.library(library))
        store.apply(.counts(counts))
        if waitingApproval {
            guard let draft = store.drafts.first(where: { !$0.desktopOnly }) else {
                preconditionFailure("the demo queue holds no draft that the phone may act on")
            }
            let now = currentTimeMs()
            let decision = try store.decide(Target(targetType: .draft, id: draft.id), action: .approve, text: nil,
                                            scopeOptionId: nil, now: now)
            store.markSent(decisionId: decision.decisionId, seq: 1, now: now)
            store.apply(relayFrame: .stored(to: .pc, seq: 1))
            precondition(store.status(of: decision.target) == .waitingForPC, "the staged approval is not waiting for the PC")
        }
        return store
    }
}
