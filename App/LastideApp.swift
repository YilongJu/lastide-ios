import LastideKit
import SwiftUI

/// The screens a screenshot run can open, named by the launch argument `-LastideScreen`.
enum ScreenshotScreen: String, CaseIterable, Sendable {
    case queue, draftDetail, library, ruleDetail, learning, settings
    case pairingDisclosure, pairingScan, pairingWaiting, pairingCode, pairingFailed
    /// Two synthetic paired PCs: WORKSTATION-A, shown and online, and STUDIO-LAPTOP, offline and last seen 3 hours ago.
    case settingsPaired
    /// The same PC, with one approval that the relay stored and the PC has not answered yet.
    case queueWaiting
    /// The same PC, with an empty queue.
    case queueEmpty
    /// The same PC's Library while it does not measure violations yet: the counters arrive as null.
    case libraryNotMeasured
    /// The same PC's Learning screen while it does not measure repeat corrections, violations or a daily cap yet.
    case learningNotMeasured
    /// The waiting count as the small home screen widget and the lock screen widget draw it (design section 6.7).
    case widgetSmall, widgetRectangular
    /// The Settings screen of the paired PC with notifications on and registered, and with them off in iOS Settings.
    case settingsNotificationsOn, settingsNotificationsOff
    /// The learning drill-down on the demo lists (learning evidence design, check U1): this week's repeat corrections,
    /// a turn with its violation, its group, a rule, a draft, a run, today's runs and the Weeks group.
    case learningList, learningTurn, learningGroup, learningRule, learningDraft, learningRun, learningRuns, learningWeeks
    /// The same PC, WORKSTATION-A, at revision 4: online, offline, and a list whose number differs from the screen's.
    case learningPaired, learningOffline, learningMismatch
    /// The same PC at revision 3: the numbers, and a list that asks to update Lastide on the PC.
    case learningOlderPC, learningOlderPCList
    /// A turn's Show My Words on the online PC: the words (one fixed synthetic sentence), and each state that shows none.
    case learningWords, learningWordsLimited, learningWordsRemoved, learningWordsGone, learningWordsNoAnswer
    /// A Library rule's "Violations since approval", which opens the rule's list.
    case libraryViolations
    /// The Review tab with the sheet that shows once after an update, for the build the bundled changelog describes next.
    case whatsNewSheet
    /// The Settings tab, whose What's New screen reads a made-up changelog that does not parse.
    case whatsNewMalformed

    /// True for the two widget screens, which draw the widget's view instead of the tabs.
    var isWidget: Bool { self == .widgetSmall || self == .widgetRectangular }
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
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase
    private let runtime = AppRuntime.shared
    private let background = BackgroundFlush()

    var body: some Scene {
        WindowGroup {
            Group {
                if let screenshot = runtime.screenshot, screenshot.screen.isWidget {
                    WidgetScreenshotView(style: screenshot.screen == .widgetSmall ? .small : .rectangular)
                } else {
                    RootView(model: runtime.model, whatsNew: runtime.whatsNew, screenshot: runtime.screenshot?.screen)
                }
            }
            .preferredColorScheme(runtime.screenshot.map { $0.dark ? .dark : .light })
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            guard runtime.screenshot == nil else { return }
            let model = runtime.model
            switch phase {
            case .active:
                model.cameToScreen()
            case .inactive:
                // The app switcher takes its picture once the scene leaves the active state, so the words go first
                // (learning evidence design, Table 12).
                model.sceneLeftActive()
            case .background:
                background.run { await model.leftScreen() }
            @unknown default:
                model.sceneLeftActive()
            }
        }
    }
}

extension ScreenshotStaging {
    /// The demo model of one screenshot screen. It never reads the disk, the Keychain or the network.
    @MainActor
    static func model(for screen: ScreenshotScreen, facts: DeviceFacts) throws -> AppModel {
        let model = try AppModel(demoWith: facts, sockets: URLSessionSocketFactory())
        switch screen {
        case .pairingDisclosure: model.showPairingStep(.disclosure)
        case .pairingScan: model.showPairingStep(.scan)
        case .pairingWaiting: model.showPairingStep(.waitingForPC)
        // The check code of the Lastide test vector (protocol section 10.3).
        case .pairingCode: model.showPairingStep(.checkCode("714 390"))
        case .pairingFailed: model.showPairingStep(.failed(AppText.unreachable))
        case .settingsPaired:
            model.showForScreenshot(records: [try record(), try secondRecord()], store: try store(queue: true),
                                    pcOnline: true)
        case .settingsNotificationsOn:
            model.showForScreenshot(records: [try record()], store: try store(queue: true), permission: .on,
                                    registered: true)
        case .settingsNotificationsOff:
            model.showForScreenshot(records: [try record()], store: try store(queue: true), permission: .off)
        case .queueWaiting:
            model.showForScreenshot(records: [try record()], store: try store(queue: true, waitingApproval: true))
        case .queueEmpty:
            model.showForScreenshot(records: [try record()], store: try store(queue: false))
        case .libraryNotMeasured, .learningNotMeasured:
            model.showForScreenshot(records: [try record()], store: try store(queue: true, measured: false))
            model.fixClockForScreenshot(at: try DemoFixtures.load().counts.sentAt + 120_000)
        case .learningPaired, .learningMismatch, .learningWords, .learningWordsLimited, .learningWordsRemoved, .learningWordsGone,
             .learningWordsNoAnswer, .learningOffline, .learningOlderPC, .learningOlderPCList:
            try LearningStaging.stage(screen, model: model)
        case .queue, .draftDetail, .library, .ruleDetail, .learning, .settings, .widgetSmall, .widgetRectangular,
             .learningList, .learningTurn, .learningGroup, .learningRule, .learningDraft, .learningRun, .learningRuns,
             .learningWeeks, .libraryViolations, .whatsNewSheet, .whatsNewMalformed:
            break
        }
        return model
    }
}

/// Synthetic pairings and stores for the screenshots of a paired phone. Every value is made up.
enum ScreenshotStaging {
    /// A PC named WORKSTATION-A on the placeholder relay origin, paired a day ago and last seen 2 min ago.
    static func record() throws -> PairingRecord {
        try record(name: "WORKSTATION-A", firstByte: 0, lastSeenAgoMs: 120_000)
    }

    /// A second PC, STUDIO-LAPTOP, paired a day ago and last seen 3 hours ago.
    static func secondRecord() throws -> PairingRecord {
        try record(name: "STUDIO-LAPTOP", firstByte: 100, lastSeenAgoMs: 3 * 3_600_000)
    }

    /// A synthetic record. `firstByte` makes its pairing id, PC key and phone id differ from another record's.
    static func record(name: String, firstByte: Int, lastSeenAgoMs: Int, pcSchema: Int = LastideProtocol.schemaRevision)
        throws -> PairingRecord {
        let now = currentTimeMs()
        let json: [String: Any] = [
            "pairingId": Base64URL.encode(Data((firstByte..<firstByte + 16).map { UInt8($0) })),
            "relayOrigin": "https://relay.example",
            "pcKey": Base64URL.encode(Data((firstByte + 32..<firstByte + 64).map { UInt8($0) })),
            "pcName": name,
            "pcSchema": pcSchema,
            "phoneId": Base64URL.encode(Data((firstByte + 16..<firstByte + 32).map { UInt8($0) })),
            "pairedAt": now - 86_400_000,
            "pcLastSeenAt": now - lastSeenAgoMs,
            "lastSentSeq": 0,
            "lastRecvSeq": 0,
            "features": ["mailbox", "push"],
            "attestKeyId": "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=",
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
            // Before the PC's first call nothing is measured (protocol 7.3, field notes).
            counts.measuredFrom = .some(nil)
            counts.repeatCorrectionsLastWeekByNow = .some(nil)
            counts.violationsLastWeekByNow = .some(nil)
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
