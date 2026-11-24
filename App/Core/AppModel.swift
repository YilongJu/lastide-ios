#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import LastideKit
import Observation

/// The state of the session socket to the selected PC.
enum ConnectionState: Equatable, Sendable {
    case closed
    case connecting
    /// The relay sent `welcome`.
    case open
}

/// Evidence words of the draft on the detail screen (protocol section 7.2). They live in memory only.
struct OpenEvidence: Equatable, Sendable {
    let draftID: String
    let requestID: String
    var evidence: Evidence?
}

/// The words of the one turn row on the screen (protocol section 7.6). They live in memory only, until the row's screen
/// closes or the app leaves the active state.
struct OpenWords: Equatable, Sendable {
    /// The row's turn reference.
    let ref: String
    /// The request that waits for its answer, or nil once the answer came or the phone did not ask.
    var requestID: String?
    var phase: LearningWordsPhase
    /// When the request left, in ms, for the 10 s limit.
    var sentAt: Int?
}

/// What the screenshot model shows on the learning screens of a synthetic paired PC. Nothing connects.
struct StagedLearning: Sendable {
    /// Whether the synthetic PC answers. Offline, a list reads "Appears while your PC is online".
    var online: Bool
    /// The answer every Show My Words gets. It is never `words`, because a screenshot never shows words.
    var words: LearningWordsPhase?
    /// Added to every list's number, to stage the mismatch line of design Table 10.
    var valueShift = 0
}

/// The stores of a loaded model: the app's own files, the App Group files and the Keychain in the shared group.
struct LiveStores: Sendable {
    let files: AppFiles
    let group: GroupFiles
    let secrets: SecretStore
    /// Where builds before phase 7 kept `pairings.json`. The Keychain sweep waits while that file exists (design 6.2).
    let oldPairingsURL: URL?
}

/// The system services the model calls. The hosted tests hand it fakes.
@MainActor
struct ModelServices {
    let sockets: RelaySocketFactory
    let frames: FramesPoster
    let notices: LocalNotices
    let access: NotificationAccess
    let widgets: WidgetPushSource
    let attester: AppAttester
    let lock: DeviceLock

    /// The real services.
    static func live() -> ModelServices {
        ModelServices(sockets: URLSessionSocketFactory(), frames: URLSessionFramesPoster(), notices: UserNotificationsPoster(),
                      access: UserNotificationsAccess(), widgets: WidgetKitPushSource(), attester: DeviceCheckAttester(),
                      lock: SystemDeviceLock())
    }
}

/// What the model did with one lock-screen Approve or Delete (design section 6.5).
enum NoticeActionResult: Equatable, Sendable {
    /// The decision went on the open socket to that room.
    case sentOnSocket
    /// The relay answered `/frames` with 202.
    case stored
    /// The decision waits in the outbox for the next connection. The text says why.
    case notSent(String)
    /// The model sent nothing. The text names the failed check.
    case refused(String)
    /// The model sent nothing, because the phone was locked when the action arrived.
    case locked
}

/// Everything the screens draw, and every action the screens take.
///
/// Before any pairing the model runs demo mode on the package's fixtures, and never opens a socket (section 8.1).
/// After a pairing it keeps one session socket to the selected PC open while the app is on the screen (section 6.8).
/// The model reads no file until `load` runs, because a background launch on a locked phone cannot open the cache and
/// the outbox (design section 6.6).
@MainActor
@Observable
final class AppModel {
    // MARK: What the screens draw

    private(set) var store: ReviewStore
    private(set) var records: [PairingRecord] = []
    private(set) var selectedID: PairingID?
    /// Pairings whose Keychain items are missing. Each reads "Pair this phone again" until the person removes it.
    private(set) var brokenIDs: Set<PairingID> = []
    private(set) var connection: ConnectionState = .closed
    private(set) var pcOnline = false
    private(set) var diagnostics = Diagnostics()
    private(set) var evidence: OpenEvidence?
    /// The open learning lists, one per subject on a screen (protocol section 7.6). They live in memory only.
    private(set) var learningLists: [LearningSubject: LearningList] = [:]
    /// The words of the turn row on the screen.
    private(set) var learningWords: OpenWords?
    /// Rises each time the app returns to the active state, so each open list and draft screen asks again.
    private(set) var screenGeneration = 0
    /// The newest thresholds a page carried, for a row's detail.
    private(set) var learningThresholds: LearningThresholds?
    /// A sentence to show once, such as a refusal or a close code's text.
    var notice: String?
    /// True after the room was deleted (close code 4404). Settings offers to remove the PC.
    private(set) var roomGone = false
    private(set) var preferences = Preferences()
    /// True once `load` read the files.
    private(set) var isLoaded = false
    /// A launch error that stops the app before it reads another file, such as a missing App Group container.
    var launchError: String?
    /// What iOS allows the app to show.
    private(set) var permission: NotificationPermission = .unknown
    /// `settings.json` of the App Group.
    private(set) var groupSettings = GroupSettings.standard
    /// The pairings whose relay answered `ok` to an alert `push-token` with a token.
    private(set) var registeredIDs: Set<PairingID> = []
    /// The notification service extension's last run, read from the App Group.
    private(set) var extensionRun: ExtensionRun?
    /// True while the question "Get a notification when a rule waits for your review?" shows.
    var askNotifications = false
    let facts: DeviceFacts
    @ObservationIgnored private(set) var pairingFlow: PairingFlow!

    var isDemo: Bool { store.isDemo }
    var selectedRecord: PairingRecord? { records.first { $0.pairingId == selectedID } }

    // MARK: What the model keeps out of view

    @ObservationIgnored private let live: Bool
    @ObservationIgnored private var stores: LiveStores?
    @ObservationIgnored private let services: ModelServices
    @ObservationIgnored private let now: () -> Int
    @ObservationIgnored private var session: PCSession?
    @ObservationIgnored private var phoneToken: Data?
    @ObservationIgnored private var socket: RelaySocket?
    @ObservationIgnored private var backoff = ReconnectBackoff()
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private let keepAlive = KeepAlive()
    @ObservationIgnored private var onScreen = false
    /// Files that could not be written while the phone was locked. The model writes them again on return to the screen.
    @ObservationIgnored private var unsavedReviewFiles = false
    /// The `seq` of each envelope the relay answered with `stored` or `dropped` on the current socket.
    @ObservationIgnored private var storedSeqs: Set<UInt64> = []
    @ObservationIgnored private var droppedSeqs: Set<UInt64> = []
    /// The app's device token for alert and background pushes, once iOS gave it.
    @ObservationIgnored private var deviceToken: Data?
    /// True while the current socket's `welcome` listed `push`.
    @ObservationIgnored private var relayPush = false
    /// The `rid` of each `push-token` frame on the current socket, with its type and whether it carried a token.
    @ObservationIgnored private var pushRids: [String: (PushTokenType, Bool)] = [:]
    @ObservationIgnored private var ridCounter = 0
    /// Rooms with a `/frames` request in flight. The model opens no socket to them until the POST answers (design 6.5).
    @ObservationIgnored private var postingFrames: Set<PairingID> = []
    /// The demo's lists, loaded on the first open in demo mode.
    @ObservationIgnored private var demoLearning: DemoLearning?
    /// The screenshot model's learning answers.
    @ObservationIgnored private var stagedLearning: StagedLearning?
    /// The screenshot model's clock for the learning screens, so each picture shows the same dates.
    @ObservationIgnored private var fixedClock: Int?

    private var files: AppFiles? { stores?.files }
    private var group: GroupFiles? { stores?.group }
    private var secrets: SecretStore? { stores?.secrets }

    /// A model for the app's real files and Keychain. It reads nothing until `load`.
    init(facts: DeviceFacts, services: ModelServices, now: @escaping () -> Int) throws {
        self.facts = facts
        self.services = services
        self.now = now
        live = true
        store = try ReviewStore.demo()
        pairingFlow = makePairingFlow()
    }

    /// A demo model that never touches the disk, the Keychain or the network, for the screenshots.
    init(demoWith facts: DeviceFacts, sockets: RelaySocketFactory) throws {
        self.facts = facts
        services = ModelServices(sockets: sockets, frames: URLSessionFramesPoster(), notices: UserNotificationsPoster(),
                                 access: UserNotificationsAccess(), widgets: WidgetKitPushSource(),
                                 attester: UnsupportedAttester(), lock: SystemDeviceLock())
        now = currentTimeMs
        live = false
        store = try ReviewStore.demo()
        // A fresh install has not asked yet, so the screenshots show that state unless a screen names another.
        permission = .notAsked
        pairingFlow = makePairingFlow()
    }

    /// Fixes the pairing flow at one step, for the screenshots.
    func showPairingStep(_ step: PairingStep) {
        precondition(!live, "only the screenshot model fixes the pairing step")
        pairingFlow = PairingFlow.fixed(at: step, facts: facts, sockets: services.sockets)
    }

    /// Shows synthetic paired PCs and a synthetic store, for the screenshots. Nothing connects, and nothing is written.
    func showForScreenshot(records: [PairingRecord], store: ReviewStore, permission: NotificationPermission = .notAsked,
                           registered: Bool = false, pcOnline: Bool = false, learning: StagedLearning? = nil) {
        precondition(!live, "only the screenshot model shows synthetic pairings")
        self.records = records
        self.pcOnline = pcOnline
        selectedID = records.first?.pairingId
        self.store = store
        self.permission = permission
        registeredIDs = registered ? Set(records.map(\.pairingId)) : []
        stagedLearning = learning
    }

    /// Fixes the clock of the learning screens, for the screenshots.
    func fixClockForScreenshot(at time: Int) {
        precondition(!live, "only the screenshot model fixes its clock")
        fixedClock = time
    }

    private func makePairingFlow() -> PairingFlow {
        PairingFlow(facts: facts, sockets: services.sockets, attester: services.attester, now: now,
                    consentAcceptedAt: { [weak self] in self?.preferences.disclosureAcceptedAt },
                    onAccepted: { [weak self] result, keyId in self?.completePairing(result, attestKeyId: keyId) },
                    onError: { [weak self] text in self?.diagnostics.lastError = text })
    }

    // MARK: Launch

    /// Reads the preferences, `pairings.json` and the settings, sweeps the Keychain, and shows the chosen PC
    /// (protocol section 4.7, design section 6.2). Throws when a file cannot open, such as on a locked phone, and then
    /// keeps nothing it read.
    func load(_ stores: LiveStores) throws {
        precondition(live, "the screenshot model reads no file")
        let preferences = try stores.files.loadPreferences()
        let records = try stores.group.loadRecords()
        let settings = try stores.group.loadSettings()
        let moveDone = stores.oldPairingsURL.map { !FileManager.default.fileExists(atPath: $0.path) } ?? true
        if moveDone {
            let named = Set(records.map(\.pairingId.base64url))
            for account in try stores.secrets.allAccounts() where !named.contains(SecretAccount.pairingID(of: account)) {
                try stores.secrets.delete(account: account)
            }
        }
        diagnostics.sharedKeychainItems = try stores.secrets.allAccounts().count
        var broken: Set<PairingID> = []
        for record in records {
            let key = try stores.secrets.load(account: SecretAccount.key(record.pairingId))
            let token = try stores.secrets.load(account: SecretAccount.token(record.pairingId))
            if key == nil || token == nil { broken.insert(record.pairingId) }
        }
        self.stores = stores
        self.preferences = preferences
        self.records = records
        groupSettings = settings
        brokenIDs = broken
        extensionRun = try? stores.group.loadExtensionRun()
        if !moveDone { diagnostics.lastError = "the pairings move has not finished, so the Keychain sweep waits" }
        let selectable = records.filter { !broken.contains($0.pairingId) }
        do {
            if let chosen = preferences.selectedPairingID, selectable.contains(where: { $0.pairingId == chosen }) {
                try select(chosen)
            } else if let first = selectable.first {
                try select(first.pairingId)
            }
        } catch {
            self.stores = nil
            self.records = []
            brokenIDs = []
            selectedID = nil
            session = nil
            phoneToken = nil
            store = try ReviewStore.demo()
            throw error
        }
        isLoaded = true
        if onScreen { refreshPermission() }
    }

    /// Shows one paired PC. The cache and the outbox open only while the phone is unlocked, so call this in the foreground.
    func select(_ id: PairingID) throws {
        guard let files, let secrets else { preconditionFailure("select runs on a loaded model") }
        guard let record = records.first(where: { $0.pairingId == id }), !brokenIDs.contains(id) else {
            preconditionFailure("select names a pairing that is not usable")
        }
        disconnect()
        guard let keyBytes = try secrets.load(account: SecretAccount.key(id)),
              let token = try secrets.load(account: SecretAccount.token(id))
        else { preconditionFailure("a usable pairing lacks its Keychain items") }
        let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: keyBytes)
        let newSession = try PCSession(record: record, phoneKey: key)
        let newStore = ReviewStore(cache: try files.loadCache(id), outbox: try files.loadOutbox(id))
        session = newSession
        phoneToken = token
        store = newStore
        selectedID = id
        preferences.selectedPairingID = id
        try files.savePreferences(preferences)
        pcOnline = false
        roomGone = false
        evidence = nil
        dropLearning()
        if onScreen { connect() }
    }

    // MARK: The app on the screen and in the background

    /// The app came to the screen: open the socket (protocol section 6.8).
    func cameToScreen() {
        onScreen = true
        screenGeneration += 1
        if unsavedReviewFiles { saveReviewFiles() }
        backoff.reset()
        connect()
        if isLoaded {
            refreshPermission()
            extensionRun = try? group?.loadExtensionRun()
        }
    }

    /// The app left the screen. Sends the outbox decisions that lack `stored`, waits up to 5 s, then closes with 1000.
    /// Drops evidence words and reply keys. Demo mode resets its copy.
    func leftScreen() async {
        onScreen = false
        sceneLeftActive()
        reconnectTask?.cancel()
        reconnectTask = nil
        if store.isDemo {
            store = try! ReviewStore.demo()
            return
        }
        if connection == .open {
            let waiting = sendOutbox(onlyUnstored: true)
            if !waiting.isEmpty {
                _ = await waitForStored(waiting, timeoutNs: 5_000_000_000)
            }
        }
        disconnect()
    }

    // MARK: Pairing

    /// The person agreed to the disclosure `outside-ai-v1`.
    func acceptDisclosure() throws {
        preferences.disclosureAcceptedAt = now()
        if let files { try files.savePreferences(preferences) }
        pairingFlow.disclosureAccepted()
    }

    /// Stores a finished pairing: the Keychain items first, then the record, then the session (protocol section 4.3, step 21).
    private func completePairing(_ result: PairingResult, attestKeyId: String?) {
        guard let group, let secrets else { preconditionFailure("only a loaded model pairs") }
        do {
            let id = result.record.pairingId
            var record = result.record
            record.attestKeyId = attestKeyId
            try secrets.save(result.phoneKey.rawRepresentation, account: SecretAccount.key(id))
            try secrets.save(result.phoneToken, account: SecretAccount.token(id))
            records.removeAll { $0.pairingId == id }
            records.append(record)
            try group.saveRecords(records)
            brokenIDs.remove(id)
            try select(id)
            if permission == .notAsked { askNotifications = true }
        } catch {
            diagnostics.lastError = "pairing not stored: \(error)"
            notice = "This phone could not store the pairing. Scan a new code."
        }
    }

    /// Revokes a PC from the phone (protocol Table 19, "Remove PC"). Sends `unpair` and waits up to 10 s for `stored`,
    /// then deletes the Keychain items, the record, the cache, the outbox and the App Group records.
    func revoke(_ id: PairingID) async {
        guard let files, let group, let secrets else { return }
        if id == selectedID, !brokenIDs.contains(id) {
            if connection != .open {
                connect()
                _ = await waitForOpen(timeoutNs: 10_000_000_000)
            }
            if connection == .open, let seq = sendSealed(.unpair(Unpair(id: makeMessageID(), sentAt: now()))) {
                _ = await waitForStored([seq], timeoutNs: 10_000_000_000)
            }
            disconnect()
            session = nil
            phoneToken = nil
            selectedID = nil
        }
        do {
            try secrets.delete(account: SecretAccount.key(id))
            try secrets.delete(account: SecretAccount.token(id))
            records.removeAll { $0.pairingId == id }
            brokenIDs.remove(id)
            registeredIDs.remove(id)
            try group.saveRecords(records)
            try files.deleteFiles(of: id)
            try group.deleteFiles(of: id)
            if preferences.selectedPairingID == id {
                preferences.selectedPairingID = nil
                try files.savePreferences(preferences)
            }
            if selectedID == nil {
                if let next = records.first(where: { !brokenIDs.contains($0.pairingId) }) {
                    try select(next.pairingId)
                } else {
                    store = try ReviewStore.demo()
                    roomGone = false
                }
            }
            noteWaitingCounts()
        } catch {
            diagnostics.lastError = "revoke not finished: \(error)"
        }
    }

    // MARK: Decisions

    /// Takes one action on a draft or a rule. Returns the sentence to show when the phone refused to build it.
    @discardableResult
    func decide(_ target: Target, action: DecisionAction, text: String?, scopeOptionId: String?) -> String? {
        do {
            let decision = try store.decide(target, action: action, text: text, scopeOptionId: scopeOptionId, now: now())
            guard !store.isDemo else { return nil }
            saveReviewFiles()
            if connection == .open { send(decision) }
            return nil
        } catch let error as ReviewError {
            return AppText.reviewError(error)
        } catch {
            diagnostics.lastError = "decision not built: \(error)"
            return "This phone could not build the decision."
        }
    }

    // MARK: Lock-screen actions

    /// Acts on a lock-screen Approve or Delete (design section 6.5, steps 2 to 10). `envelope` is `lastide.e` of the
    /// notification, and `shown` the text iOS showed. The model sends nothing unless the envelope opens, its `seq` is
    /// the `shownSeq` the extension wrote, and the shown text is the extension's.
    func actOnNotice(envelope: Data?, action: DecisionAction, shown: NotificationText) async -> NoticeActionResult {
        let result = await act(envelope: envelope, action: action, shown: shown)
        diagnostics.lastNotificationAction = "\(action.rawValue): \(result)"
        switch result {
        case .refused: services.notices.post(PushText.actionRefused)
        case .locked: services.notices.post(PushText.actionLocked)
        case .notSent: services.notices.post(PushText.actionNotSent(action))
        case .sentOnSocket, .stored: break
        }
        return result
    }

    private func act(envelope: Data?, action: DecisionAction, shown: NotificationText) async -> NoticeActionResult {
        // The model stays loaded after the phone locks, so the model checks the lock itself. An action from a paired
        // Apple Watch can arrive while the phone stays locked (design 6.5, step 1).
        guard services.lock.isUnlocked else { return .locked }
        guard let files, let group, let secrets, isLoaded else { return .refused("the app has not loaded its files") }
        guard let envelope else { return .refused("the notification holds no envelope") }
        let opened: OpenedPush
        do {
            opened = try PushOpener.open(envelope, slot: PushOpener.noticeSlot, records: records,
                                         phoneKey: { try secrets.load(account: SecretAccount.key($0.pairingId)) })
        } catch {
            return .refused("open: \(error)")
        }
        let id = opened.record.pairingId
        let notice: Notice
        do {
            let state = try group.loadPush(id)
            notice = try NoticeActionGuard.check(opened, shownSeq: state?.shownSeq, shown: shown)
        } catch {
            return .refused("guard: \(error)")
        }
        guard !brokenIDs.contains(id) else { return .refused("the pairing lacks its Keychain items") }

        if id == selectedID {
            let decision: Decision
            do { decision = try store.decideFromNotice(notice, action: action, now: now()) } catch {
                return .refused("decision: \(error)")
            }
            saveReviewFiles()
            if connection == .open {
                send(decision)
                return .sentOnSocket
            }
            guard var session, let token = phoneToken else { return .notSent("no session") }
            let sealed: SealedEnvelope
            do { sealed = try session.seal(.decision(decision), now: now()) } catch {
                return .notSent("not sealed: \(error)")
            }
            self.session = session
            guard saveRecord() else { return .notSent("pairings.json not written") }
            store.markSent(decisionId: decision.decisionId, seq: sealed.seq, now: now())
            saveReviewFiles()
            let answer = await postFrames(FramesRequest(record: session.record, token: token, envelope: sealed.bytes), id)
            if answer.isStored, selectedID == id {
                store.apply(relayFrame: .stored(to: .pc, seq: sealed.seq))
                saveReviewFiles()
            }
            return result(of: answer, id)
        }

        guard let index = records.firstIndex(where: { $0.pairingId == id }) else { return .refused("no record") }
        do {
            guard let keyBytes = try secrets.load(account: SecretAccount.key(id)),
                  let token = try secrets.load(account: SecretAccount.token(id))
            else { return .refused("the pairing lacks its Keychain items") }
            var other = ReviewStore(cache: try files.loadCache(id), outbox: try files.loadOutbox(id))
            let decision = try other.decideFromNotice(notice, action: action, now: now())
            var otherSession = try PCSession(record: records[index],
                                             phoneKey: try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: keyBytes))
            let sealed = try otherSession.seal(.decision(decision), now: now())
            records[index] = otherSession.record
            try group.saveRecords(records)
            other.markSent(decisionId: decision.decisionId, seq: sealed.seq, now: now())
            try files.saveCache(other.cache, id)
            try files.saveOutbox(other.outbox, id)
            let answer = await postFrames(FramesRequest(record: otherSession.record, token: token, envelope: sealed.bytes), id)
            if answer.isStored {
                other.apply(relayFrame: .stored(to: .pc, seq: sealed.seq))
                try files.saveOutbox(other.outbox, id)
            }
            return result(of: answer, id)
        } catch {
            return .notSent("not stored on the phone: \(error)")
        }
    }

    /// Posts one `/frames` request. The model opens no socket to that room until the answer arrives.
    private func postFrames(_ request: FramesRequest, _ id: PairingID) async -> FramesAnswer {
        postingFrames.insert(id)
        let answer = await services.frames.post(request)
        postingFrames.remove(id)
        if onScreen, selectedID == id { connect() }
        return answer
    }

    private func result(of answer: FramesAnswer, _ id: PairingID) -> NoticeActionResult {
        switch answer {
        case .stored:
            return .stored
        case .roomGone:
            if id == selectedID {
                roomGone = true
                notice = AppText.roomGone
            }
            return .notSent("roomGone")
        case .notAttested:
            notice = RelayCloseCode.attestationRefused.displayText(pairing: false)
            return .notSent("notAttested")
        case .refused(let text):
            return .notSent(text)
        }
    }

    // MARK: Notifications

    /// Reads the permission, and asks the question once at the first launch that holds a pairing (design 6.3).
    func refreshPermission() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let (permission, _) = await self.services.access.read()
            self.permission = permission
            if permission == .notAsked, !self.records.isEmpty, self.preferences.notificationQuestionAt == nil {
                self.askNotifications = true
            }
        }
    }

    /// The person answered "Get a notification when a rule waits for your review?". Turn On asks iOS.
    func answerNotificationQuestion(turnOn: Bool) async {
        askNotifications = false
        preferences.notificationQuestionAt = now()
        if let files {
            do { try files.savePreferences(preferences) } catch { diagnostics.lastError = "preferences not written: \(error)" }
        }
        guard turnOn else { return }
        permission = await services.access.request()
        await registerTokens()
    }

    /// The switch "Show rule text in notifications" changed.
    func setShowRuleText(_ on: Bool) {
        groupSettings.showRuleText = on
        saveGroupSettings()
    }

    /// The switch "Show rule text while iPhone is locked" changed.
    func setShowRuleTextWhenLocked(_ on: Bool) {
        groupSettings.showRuleTextWhenLocked = on
        saveGroupSettings()
    }

    private func saveGroupSettings() {
        guard let group else { return }
        do { try group.saveSettings(groupSettings) } catch { diagnostics.lastError = "settings.json not written: \(error)" }
    }

    /// iOS gave the device token. It goes out at once on an open socket whose relay lists `push`.
    func deviceTokenArrived(_ token: Data) {
        deviceToken = token
        if relayPush, connection == .open { Task { await self.registerTokens() } }
    }

    /// `registerForRemoteNotifications` failed.
    func registrationFailed(_ text: String) {
        diagnostics.lastRegistrationError = text
    }

    /// Records a launch or background problem for the diagnostics block.
    func noteProblem(_ text: String) {
        diagnostics.lastError = text
    }

    /// Records what the moves of design section 6.2 did at this launch, for the diagnostics block.
    func noteLaunchMoves(_ text: String) {
        diagnostics.launchMoves = text
    }

    /// A count update changed `counts/`: reload the widget and set the badge from the App Group.
    func waitingCountsChanged(group: GroupFiles) {
        services.widgets.reloadTimelines()
        if let counts = try? group.waitingCounts() { services.notices.setBadge(WaitingCount.badge(counts)) }
    }

    /// Sends the alert and widgets `push-token` frames after a `welcome` that lists `push` (design 6.3).
    /// The alert frame carries `null` while iOS does not allow the app's alerts (P6).
    private func registerTokens() async {
        guard relayPush, connection == .open, let socket else { return }
        let (permission, _) = await services.access.read()
        self.permission = permission
        let widget = await services.widgets.current(group: group)
        guard relayPush, connection == .open, self.socket === socket else { return }
        if permission != .on {
            sendPushToken(.alert, nil)
        } else if let deviceToken {
            sendPushToken(.alert, deviceToken)
        }
        sendPushToken(.widgets, widget.widgets > 0 ? widget.token : nil)
    }

    private func sendPushToken(_ type: PushTokenType, _ token: Data?) {
        ridCounter += 1
        let rid = "p\(ridCounter)"
        pushRids[rid] = (type, token != nil)
        socket?.send(text: ControlFrame.pushToken(rid: rid, type: type, token: token, environment: facts.pushEnvironment))
    }

    /// Writes `counts/` for the selected PC after a queue snapshot, reloads the widget and sets the badge.
    private func noteWaitingCount() {
        guard let group, let id = selectedID, let queue = store.cache.queue else { return }
        do {
            try group.saveCount(CountState(storeVersion: queue.storeVersion, queueCount: store.badgeCount, at: now()), id)
        } catch {
            diagnostics.lastError = "counts not written: \(error)"
            return
        }
        noteWaitingCounts()
    }

    private func noteWaitingCounts() {
        guard let group else { return }
        services.widgets.reloadTimelines()
        if let counts = try? group.waitingCounts() { services.notices.setBadge(WaitingCount.badge(counts)) }
    }

    /// The push and attestation lines of the diagnostics block.
    var pushFacts: Diagnostics.PushFacts {
        let run = extensionRun.map { run in
            let memory = run.peakMemory.map { "\($0 / 1_024) KiB peak" } ?? "peak memory unknown"
            return "\(run.outcome), \(memory), \(AppText.age(ms: max(0, currentTimeMs() - run.at)))"
        }
        return Diagnostics.PushFacts(environment: facts.pushEnvironment.rawValue, permission: permission.label,
                                     attestations: records.map { "\($0.pcName): \($0.attestKeyId == nil ? "none" : "attested")" },
                                     extensionRun: run)
    }

    // MARK: Evidence words

    /// The app's scene left the active state: drop every word, page and reply key at once, before iOS takes the app
    /// switcher picture (design Table 12). The draft screen and each list ask again when the app is active again.
    func sceneLeftActive() {
        evidence = nil
        dropLearning()
        session?.dropReplyKeys()
    }

    /// The detail screen of a draft opened. Asks the PC for the words while it is online (protocol section 7.2).
    func openEvidence(draftID: String) {
        closeEvidence()
        guard !store.isDemo, connection == .open, pcOnline, session != nil,
              let version = store.seenAt(Target(targetType: .draft, id: draftID))
        else { return }
        let request = session!.makeEvidenceRequest(draftID: draftID, storeVersion: version, now: now())
        evidence = OpenEvidence(draftID: draftID, requestID: request.id, evidence: nil)
        _ = sendSealed(.evidenceRequest(request))
    }

    /// The detail screen closed: drop the words and the reply key of its request. A learning row's key stays.
    func closeEvidence() {
        if let requestID = evidence?.requestID { session?.dropReplyKey(requestID: requestID) }
        evidence = nil
    }

    /// The number of reply keys that wait for an answer, for the hosted tests.
    var waitingReplyKeyCount: Int { session?.waitingReplyKeyCount ?? 0 }

    // MARK: Learning lists and words (protocol section 7.6)

    /// The clock of the learning screens: the demo's own time in demo mode, so its weeks read as this week.
    var learningClock: Int {
        if let fixedClock { return fixedClock }
        if store.isDemo, let counts = store.counts { return counts.sentAt }
        return now()
    }

    /// The selected PC's schema revision, from `pair-accept` and each snapshot.
    var pcSchema: Int { selectedRecord?.pcSchema ?? LastideProtocol.schemaRevision }

    /// Whether a learning request can reach the PC now.
    private var canAskPC: Bool { connection == .open && pcOnline && session != nil }

    /// A list's screen opened, or the app came back to it. A list already on the way or shown stays as it is.
    func openList(_ subject: LearningSubject) {
        if let list = learningLists[subject], list.phase == .asking || list.phase == .shown { return }
        if store.isDemo {
            showDemoPage(subject, from: nil)
            return
        }
        guard pcSchema >= 4 else {
            learningLists[subject] = LearningList(subject: subject, phase: .needsUpdate)
            return
        }
        if let staged = stagedLearning {
            showStagedPage(subject, staged: staged, from: nil)
            return
        }
        guard canAskPC else {
            learningLists[subject] = LearningList(subject: subject, phase: .offline)
            return
        }
        let (list, request) = LearningList.ask(subject, now: now())
        learningLists[subject] = list
        sendLearning(request)
    }

    /// Show More: the next page of an open list.
    func showMore(_ subject: LearningSubject) {
        guard var list = learningLists[subject] else { return }
        guard let request = list.nextRequest(now: now()) else { return }
        learningLists[subject] = list
        if store.isDemo {
            showDemoPage(subject, from: request)
        } else if let staged = stagedLearning {
            showStagedPage(subject, staged: staged, from: request)
        } else {
            sendLearning(request)
        }
    }

    /// Try Again on a list that did not answer, changed too often or was refused.
    func retryList(_ subject: LearningSubject) {
        learningLists[subject] = nil
        openList(subject)
    }

    /// Keeps the lists whose screens are on a navigation stack, and drops every other one.
    func keepLists(_ subjects: Set<LearningSubject>) {
        for subject in learningLists.keys where !subjects.contains(subject) { learningLists[subject] = nil }
    }

    /// Show My Words on one turn row (protocol 7.6). The words come live from the PC, sealed to a fresh reply key.
    func showWords(ref: String) {
        closeWords()
        if store.isDemo {
            learningWords = OpenWords(ref: ref, requestID: nil, phase: .demo, sentAt: nil)
            return
        }
        guard pcSchema >= 4 else {
            learningWords = OpenWords(ref: ref, requestID: nil, phase: .needsUpdate, sentAt: nil)
            return
        }
        if let staged = stagedLearning {
            let phase = staged.online ? (staged.words ?? .gone) : .offline
            precondition({ if case .words = phase { return false }; return true }(), "a screenshot never shows words")
            learningWords = OpenWords(ref: ref, requestID: nil, phase: phase, sentAt: nil)
            return
        }
        guard canAskPC, var session else {
            learningWords = OpenWords(ref: ref, requestID: nil, phase: .offline, sentAt: nil)
            return
        }
        let request = session.makeLearningWordsRequest(ref: ref, now: now())
        self.session = session
        learningWords = OpenWords(ref: ref, requestID: request.id, phase: .asking, sentAt: now())
        guard sendSealed(.learningWordsRequest(request)) != nil else {
            self.session?.dropReplyKey(requestID: request.id)
            learningWords = OpenWords(ref: ref, requestID: nil, phase: .offline, sentAt: nil)
            return
        }
        let requestID = request.id
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(LearningList.answerTimeMs) * 1_000_000)
            guard let self, var open = self.learningWords, open.requestID == requestID else { return }
            self.session?.dropReplyKey(requestID: requestID)
            open.requestID = nil
            open.phase = .noAnswer
            self.learningWords = open
        }
    }

    /// The turn row's screen closed: drop its words and the reply key of its request.
    func closeWords() {
        if let requestID = learningWords?.requestID { session?.dropReplyKey(requestID: requestID) }
        learningWords = nil
    }

    private func sendLearning(_ request: LearningRequest) {
        guard sendSealed(.learningRequest(request)) != nil else {
            learningLists[request.subject] = LearningList(subject: request.subject, phase: .offline)
            return
        }
        let subject = request.subject, requestID = request.id
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(LearningList.answerTimeMs) * 1_000_000)
            guard let self, var list = self.learningLists[subject], list.pendingRequestID == requestID else { return }
            if list.checkTimeout(now: self.now()) { self.learningLists[subject] = list }
        }
    }

    private func apply(page: LearningPage) {
        guard var list = learningLists[page.subject] else { return }
        let step = list.apply(page, now: now())
        if step == .shown, let thresholds = list.thresholds { learningThresholds = thresholds }
        learningLists[page.subject] = list
        if case .askAgain(let request) = step { sendLearning(request) }
    }

    private func apply(words: LearningWords) {
        guard var open = learningWords, open.requestID == words.requestId, open.ref == words.ref else { return }
        open.requestID = nil
        switch words.state {
        case .words: open.phase = .words(words.words ?? "")
        case .removed: open.phase = .removed
        case .gone:
            open.phase = .gone
            // The row left the lists on the PC: every open list reads again (design Table 11).
            for subject in learningLists.keys { learningLists[subject] = nil }
            screenGeneration += 1
        case .limited: open.phase = .limited(nextAt: words.nextAt ?? now())
        }
        learningWords = open
    }

    private func showDemoPage(_ subject: LearningSubject, from request: LearningRequest?) {
        if demoLearning == nil {
            do { demoLearning = try DemoLearning.load() } catch { preconditionFailure("the demo learning lists do not load: \(error)") }
        }
        guard let demoLearning else { return }
        var list: LearningList
        let ask: LearningRequest
        if let request, let open = learningLists[subject] {
            list = open
            ask = request
        } else {
            (list, ask) = LearningList.ask(subject, now: demoLearning.asOf)
        }
        _ = list.apply(demoLearning.page(ask), now: demoLearning.asOf)
        if let thresholds = list.thresholds { learningThresholds = thresholds }
        learningLists[subject] = list
    }

    private func showStagedPage(_ subject: LearningSubject, staged: StagedLearning, from request: LearningRequest?) {
        guard staged.online else {
            learningLists[subject] = LearningList(subject: subject, phase: .offline)
            return
        }
        if demoLearning == nil {
            do { demoLearning = try DemoLearning.load() } catch { preconditionFailure("the demo learning lists do not load: \(error)") }
        }
        guard let demoLearning else { return }
        var list: LearningList
        let ask: LearningRequest
        if let request, let open = learningLists[subject] {
            list = open
            ask = request
        } else {
            (list, ask) = LearningList.ask(subject, now: demoLearning.asOf)
        }
        var page = demoLearning.page(ask)
        if page.state == .ok, staged.valueShift != 0 { page.value += staged.valueShift }
        _ = list.apply(page, now: demoLearning.asOf)
        if let thresholds = list.thresholds { learningThresholds = thresholds }
        learningLists[subject] = list
    }

    /// Drops every list and the words, as when the PC goes offline or another PC is picked.
    private func dropLearning() {
        learningLists = [:]
        learningWords = nil
    }

    /// The PC went offline: lists and words read "Appears while your PC is online", and their keys go.
    private func learningWentOffline() {
        for subject in learningLists.keys { learningLists[subject] = LearningList(subject: subject, phase: .offline) }
        if let open = learningWords {
            if let requestID = open.requestID { session?.dropReplyKey(requestID: requestID) }
            learningWords = OpenWords(ref: open.ref, requestID: nil, phase: .offline, sentAt: nil)
        }
    }

    /// The PC came online: each list that waited asks.
    private func learningCameOnline() {
        for (subject, list) in learningLists where list.phase == .offline {
            learningLists[subject] = nil
            openList(subject)
        }
    }

    // MARK: The session socket

    private func connect() {
        guard onScreen, socket == nil, let record = selectedRecord, let session, let phoneToken,
              !postingFrames.contains(record.pairingId)
        else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        connection = .connecting
        let socket = services.sockets.open(url: record.socketURL) { [weak self] event in self?.handle(event) }
        self.socket = socket
        socket.send(text: ControlFrame.helloPhone(device: session.record.phoneId, token: phoneToken))
        keepAlive.start(sendPing: { [weak self] in self?.socket?.send(text: ControlFrame.ping) },
                        onTimeout: { [weak self] in self?.socketFailed(code: nil, reason: "no pong within 10 s") })
    }

    private func disconnect() {
        keepAlive.stop()
        reconnectTask?.cancel()
        reconnectTask = nil
        socket?.close()
        socket = nil
        connection = .closed
        storedSeqs = []
        droppedSeqs = []
        relayPush = false
        pushRids = [:]
    }

    private func handle(_ event: SocketEvent) {
        switch event {
        case .text(let text):
            handle(text: text)
        case .binary(let frame):
            handle(frame: frame)
        case .closed(let code, let reason):
            socketFailed(code: code, reason: reason)
        }
    }

    private func handle(text: String) {
        let frame: RelayFrame
        do { frame = try ControlFrame.parse(text) } catch {
            diagnostics.lastError = "relay frame refused: \(error)"
            return
        }
        switch frame {
        case .pong:
            keepAlive.pongArrived()
        case .welcome(let welcome):
            backoff.reset()
            connection = .open
            guard let online = welcome.pcOnline else {
                preconditionFailure("ControlFrame.parse refuses a phone welcome without pcOnline")
            }
            pcOnline = online
            if let seen = welcome.pcLastSeenAt { noteLastSeen(seen) }
            if pcOnline { noteLastSeen(now()) }
            if pcOnline { learningCameOnline() } else { learningWentOffline() }
            _ = sendOutbox(onlyUnstored: false)
            _ = sendSealed(.sync(SyncRequest(id: makeMessageID(), sentAt: now(), schema: LastideProtocol.schemaRevision,
                                             have: store.have)))
            relayPush = welcome.features.contains(Feature.push.rawValue)
            if relayPush { Task { await self.registerTokens() } }
        case .presence(let device, let online):
            guard device == .pc else { return }
            pcOnline = online
            noteLastSeen(now())
            if !online {
                evidence = nil
                learningWentOffline()
            } else {
                learningCameOnline()
            }
        case .stored(_, let seq):
            store.apply(relayFrame: frame)
            saveReviewFiles()
            storedSeqs.insert(seq)
        case .dropped(_, let seq, let reason):
            store.apply(relayFrame: frame)
            saveReviewFiles()
            diagnostics.lastDroppedReason = reason
            droppedSeqs.insert(seq)
        case .ok(let rid):
            guard let entry = pushRids.removeValue(forKey: rid) else { return }
            let (type, carriedToken) = entry
            diagnostics.lastPushTokenAnswer = "\(type.rawValue): ok"
            if type == .alert, let id = selectedID {
                if carriedToken { registeredIDs.insert(id) } else { registeredIDs.remove(id) }
            }
        case .refused(let rid, let code):
            guard let rid, let entry = pushRids.removeValue(forKey: rid) else { return }
            diagnostics.lastPushTokenAnswer = "\(entry.0.rawValue): refused \(code)"
        }
    }

    private func handle(frame: Data) {
        guard var session else { return }
        let outcome = session.receive(frame, now: now())
        self.session = session
        switch outcome {
        case .ignored(let why):
            diagnostics.framesIgnored += 1
            diagnostics.lastError = "frame ignored: \(why)"
        case .duplicate(let report):
            socket?.send(text: report.controlFrame)
        case .message(let message, let report):
            apply(message)
            guard saveRecord() else { return }
            socket?.send(text: report.controlFrame)
        case .unusable(let reply, let report):
            if let reply {
                diagnostics.lastError = "message unusable: \(reply.detail)"
                _ = sendSealed(.error(reply))
            }
            guard saveRecord() else { return }
            socket?.send(text: report.controlFrame)
        }
    }

    private func apply(_ message: SyncMessage) {
        switch message {
        case .queue(let snapshot):
            session?.notePCSchema(snapshot.schema)
            store.apply(message)
            if let open = evidence, store.draft(id: open.draftID) == nil { evidence = nil }
            noteWaitingCount()
        case .library(let snapshot):
            session?.notePCSchema(snapshot.schema)
            store.apply(message)
        case .counts(let counts):
            session?.notePCSchema(counts.schema)
            store.apply(message)
        case .acknowledgement:
            if case .refused(let target, let reason) = store.apply(message) {
                notice = reason.displayText(for: target.targetType)
            }
        case .evidence(let words):
            // The session forgot the reply key once it opened the answer, so an open learning row keeps its own key.
            guard var open = evidence, open.draftID == words.draftId, open.requestID == words.requestId,
                  let draft = store.draft(id: words.draftId), draft.changedAtStoreVersion == words.changedAtStoreVersion
            else { return }
            open.evidence = words
            evidence = open
        case .learningPage(let page):
            apply(page: page)
            return
        case .learningWords(let words):
            apply(words: words)
            return
        case .error(let error):
            diagnostics.lastError = "the PC refused a message: \(error.code.rawValue), \(error.detail)"
        default:
            diagnostics.lastError = "unexpected \(message.type.rawValue) from the PC"
        }
        saveReviewFiles()
    }

    private func socketFailed(code: Int?, reason: String) {
        keepAlive.stop()
        socket?.close()
        socket = nil
        connection = .closed
        pcOnline = false
        evidence = nil
        learningWentOffline()
        session?.dropReplyKeys()
        storedSeqs = []
        droppedSeqs = []
        relayPush = false
        pushRids = [:]
        diagnostics.lastCloseCode = code
        if code == nil { diagnostics.lastError = "socket ended: \(reason)" }
        let close = code.flatMap(RelayCloseCode.init(rawValue:))
        if let text = close?.displayText(pairing: false) { notice = text }
        if close == .roomGone {
            roomGone = true
            notice = AppText.roomGone
        }
        // Table 17: 4408, 4429 and 4500 reconnect; a failure without a close code reconnects as section 6.8 says.
        guard code == nil || close?.reconnects == true else { return }
        var wait = backoff.take()
        if close == .rateLimited { wait = 10_000 }
        if close == .relayError { wait = max(wait, 5_000) }
        guard onScreen else { return }
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000)
            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }

    // MARK: Sending

    /// Sends the outbox after a `welcome`, or only the decisions that lack `stored` before the app leaves the screen.
    /// Returns the `seq` of each envelope sent.
    private func sendOutbox(onlyUnstored: Bool) -> [UInt64] {
        let decisions = onlyUnstored
            ? store.outbox.filter { !$0.stored }.map(\.decision)
            : store.decisionsToSend(now: now())
        return decisions.compactMap { send($0) }
    }

    @discardableResult
    private func send(_ decision: Decision) -> UInt64? {
        guard let seq = sendSealed(.decision(decision)) else { return nil }
        store.markSent(decisionId: decision.decisionId, seq: seq, now: now())
        saveReviewFiles()
        return seq
    }

    /// Seals one message, writes the record with the new `lastSentSeq`, then sends the envelope (protocol section 5.4).
    /// Returns the envelope's `seq`, or nil when the record could not be written and nothing left.
    private func sendSealed(_ message: SyncMessage) -> UInt64? {
        guard var session, let socket else { return nil }
        let sealed: SealedEnvelope
        do { sealed = try session.seal(message, now: now()) } catch {
            diagnostics.lastError = "message not sealed: \(error)"
            return nil
        }
        self.session = session
        guard saveRecord() else { return nil }
        socket.send(binary: sealed.bytes)
        return sealed.seq
    }

    private func noteLastSeen(_ time: Int) {
        session?.notePCLastSeen(at: time)
        _ = saveRecord()
    }

    /// Writes the session's record into `pairings.json`. Returns false when the write failed.
    private func saveRecord() -> Bool {
        guard let group, let record = session?.record else { return true }
        guard let index = records.firstIndex(where: { $0.pairingId == record.pairingId }) else { return false }
        records[index] = record
        do {
            try group.saveRecords(records)
            return true
        } catch {
            diagnostics.lastError = "pairings.json not written: \(error)"
            return false
        }
    }

    /// Writes the cache and the outbox. While the phone is locked the write fails, and the model keeps them in memory.
    private func saveReviewFiles() {
        guard let files, let id = selectedID, !store.isDemo else { return }
        do {
            try files.saveCache(store.cache, id)
            try files.saveOutbox(store.outbox, id)
            unsavedReviewFiles = false
        } catch {
            unsavedReviewFiles = true
        }
    }

    // MARK: Waiting

    /// Waits for a `stored` answer for every `seq`. A `dropped` answer, a closed socket or the time limit ends the wait.
    /// Returns true when every envelope was stored.
    private func waitForStored(_ seqs: [UInt64], timeoutNs: UInt64) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNs
        while socket != nil, DispatchTime.now().uptimeNanoseconds < deadline {
            if seqs.allSatisfy(storedSeqs.contains) { return true }
            if seqs.contains(where: droppedSeqs.contains) { return false }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return seqs.allSatisfy(storedSeqs.contains)
    }

    /// Waits until the relay sent `welcome`, the socket closed, or the time ran out.
    private func waitForOpen(timeoutNs: UInt64) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNs
        while connection != .open, socket != nil, DispatchTime.now().uptimeNanoseconds < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return connection == .open
    }
}
