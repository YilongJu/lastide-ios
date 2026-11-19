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

/// Everything the screens draw, and every action the screens take.
///
/// Before any pairing the model runs demo mode on the package's fixtures, and never opens a socket (section 8.1).
/// After a pairing it keeps one session socket to the selected PC open while the app is on the screen (section 6.8).
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
    /// A sentence to show once, such as a refusal or a close code's text.
    var notice: String?
    /// True after the room was deleted (close code 4404). Settings offers to remove the PC.
    private(set) var roomGone = false
    private(set) var preferences = Preferences()
    let facts: DeviceFacts
    @ObservationIgnored private(set) var pairingFlow: PairingFlow!

    var isDemo: Bool { store.isDemo }
    var selectedRecord: PairingRecord? { records.first { $0.pairingId == selectedID } }

    // MARK: What the model keeps out of view

    @ObservationIgnored private let storage: FileStorage?
    @ObservationIgnored private let secrets: SecretStore?
    @ObservationIgnored private let sockets: RelaySocketFactory
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

    /// A model on the app's real files and Keychain.
    init(facts: DeviceFacts, storage: FileStorage, secrets: SecretStore, sockets: RelaySocketFactory,
         now: @escaping () -> Int) throws {
        self.facts = facts
        self.storage = storage
        self.secrets = secrets
        self.sockets = sockets
        self.now = now
        store = try ReviewStore.demo()
        pairingFlow = makePairingFlow()
        try loadFromDisk()
    }

    /// A demo model that never touches the disk, the Keychain or the network, for the screenshots.
    init(demoWith facts: DeviceFacts, sockets: RelaySocketFactory) throws {
        self.facts = facts
        storage = nil
        secrets = nil
        self.sockets = sockets
        now = currentTimeMs
        store = try ReviewStore.demo()
        pairingFlow = makePairingFlow()
    }

    /// Fixes the pairing flow at one step, for the screenshots.
    func showPairingStep(_ step: PairingStep) {
        precondition(storage == nil, "only the screenshot model fixes the pairing step")
        pairingFlow = PairingFlow.fixed(at: step, facts: facts, sockets: sockets)
    }

    /// Shows synthetic paired PCs and a synthetic store, for the screenshots. Nothing connects, and nothing is written.
    func showForScreenshot(records: [PairingRecord], store: ReviewStore) {
        precondition(storage == nil, "only the screenshot model shows synthetic pairings")
        self.records = records
        selectedID = records.first?.pairingId
        self.store = store
    }

    private func makePairingFlow() -> PairingFlow {
        PairingFlow(facts: facts, sockets: sockets, now: now,
                    consentAcceptedAt: { [weak self] in self?.preferences.disclosureAcceptedAt },
                    onAccepted: { [weak self] result in self?.completePairing(result) },
                    onError: { [weak self] text in self?.diagnostics.lastError = text })
    }

    // MARK: Launch

    /// Reads `pairings.json` and checks each record against its Keychain items (protocol section 4.7).
    private func loadFromDisk() throws {
        guard let storage, let secrets else { return }
        preferences = try storage.loadPreferences()
        records = try storage.loadRecords()
        let named = Set(records.map(\.pairingId.base64url))
        for account in try secrets.allAccounts() where !named.contains(SecretAccount.pairingID(of: account)) {
            try secrets.delete(account: account)
        }
        brokenIDs = []
        for record in records {
            let key = try secrets.load(account: SecretAccount.key(record.pairingId))
            let token = try secrets.load(account: SecretAccount.token(record.pairingId))
            if key == nil || token == nil { brokenIDs.insert(record.pairingId) }
        }
        let selectable = records.filter { !brokenIDs.contains($0.pairingId) }
        if let chosen = preferences.selectedPairingID, selectable.contains(where: { $0.pairingId == chosen }) {
            try select(chosen)
        } else if let first = selectable.first {
            try select(first.pairingId)
        }
    }

    /// Shows one paired PC. The cache and the outbox open only while the phone is unlocked, so call this in the foreground.
    func select(_ id: PairingID) throws {
        guard let storage, let secrets else { preconditionFailure("the demo model has no pairings") }
        guard let record = records.first(where: { $0.pairingId == id }), !brokenIDs.contains(id) else {
            preconditionFailure("select names a pairing that is not usable")
        }
        disconnect()
        guard let keyBytes = try secrets.load(account: SecretAccount.key(id)),
              let token = try secrets.load(account: SecretAccount.token(id))
        else { preconditionFailure("a usable pairing lacks its Keychain items") }
        let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: keyBytes)
        session = try PCSession(record: record, phoneKey: key)
        phoneToken = token
        store = ReviewStore(cache: try storage.loadCache(id), outbox: try storage.loadOutbox(id))
        selectedID = id
        preferences.selectedPairingID = id
        try storage.savePreferences(preferences)
        pcOnline = false
        roomGone = false
        evidence = nil
        if onScreen { connect() }
    }

    // MARK: The app on the screen and in the background

    /// The app came to the screen: open the socket (protocol section 6.8).
    func cameToScreen() {
        onScreen = true
        if unsavedReviewFiles { saveReviewFiles() }
        backoff.reset()
        connect()
    }

    /// The app left the screen. Sends the outbox decisions that lack `stored`, waits up to 5 s, then closes with 1000.
    /// Drops evidence words and reply keys. Demo mode resets its copy.
    func leftScreen() async {
        onScreen = false
        closeEvidence()
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
        if let storage { try storage.savePreferences(preferences) }
        pairingFlow.disclosureAccepted()
    }

    /// Stores a finished pairing: the Keychain items first, then the record, then the session (protocol section 4.3, step 21).
    private func completePairing(_ result: PairingResult) {
        guard let storage, let secrets else { preconditionFailure("the demo model does not pair") }
        do {
            let id = result.record.pairingId
            try secrets.save(result.phoneKey.rawRepresentation, account: SecretAccount.key(id))
            try secrets.save(result.phoneToken, account: SecretAccount.token(id))
            records.removeAll { $0.pairingId == id }
            records.append(result.record)
            try storage.saveRecords(records)
            brokenIDs.remove(id)
            try select(id)
        } catch {
            diagnostics.lastError = "pairing not stored: \(error)"
            notice = "This phone could not store the pairing. Scan a new code."
        }
    }

    /// Revokes a PC from the phone (protocol Table 19, "Remove PC"). Sends `unpair` and waits up to 10 s for `stored`,
    /// then deletes the Keychain items, the record, the cache and the outbox.
    func revoke(_ id: PairingID) async {
        guard let storage, let secrets else { return }
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
            try storage.saveRecords(records)
            try storage.deleteFiles(of: id)
            if preferences.selectedPairingID == id {
                preferences.selectedPairingID = nil
                try storage.savePreferences(preferences)
            }
            if selectedID == nil {
                if let next = records.first(where: { !brokenIDs.contains($0.pairingId) }) {
                    try select(next.pairingId)
                } else {
                    store = try ReviewStore.demo()
                    roomGone = false
                }
            }
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

    // MARK: Evidence words

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

    /// The detail screen closed, or the app left the screen: drop the words and every reply key.
    func closeEvidence() {
        evidence = nil
        session?.dropReplyKeys()
    }

    // MARK: The session socket

    private func connect() {
        guard onScreen, socket == nil, let record = selectedRecord, let session, let phoneToken else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        connection = .connecting
        let socket = sockets.open(url: record.socketURL) { [weak self] event in self?.handle(event) }
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
            _ = sendOutbox(onlyUnstored: false)
            _ = sendSealed(.sync(SyncRequest(id: makeMessageID(), sentAt: now(), schema: LastideProtocol.schemaRevision,
                                             have: store.have)))
        case .presence(let device, let online):
            guard device == .pc else { return }
            pcOnline = online
            noteLastSeen(now())
            if !online { evidence = nil }
        case .stored(_, let seq):
            store.apply(relayFrame: frame)
            saveReviewFiles()
            storedSeqs.insert(seq)
        case .dropped(_, let seq, let reason):
            store.apply(relayFrame: frame)
            saveReviewFiles()
            diagnostics.lastDroppedReason = reason
            droppedSeqs.insert(seq)
        case .ok, .refused:
            return
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
            guard var open = evidence, open.draftID == words.draftId, open.requestID == words.requestId,
                  let draft = store.draft(id: words.draftId), draft.changedAtStoreVersion == words.changedAtStoreVersion
            else { return }
            open.evidence = words
            evidence = open
            session?.dropReplyKeys()
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
        session?.dropReplyKeys()
        storedSeqs = []
        droppedSeqs = []
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
        guard let storage, let record = session?.record else { return true }
        guard let index = records.firstIndex(where: { $0.pairingId == record.pairingId }) else { return false }
        records[index] = record
        do {
            try storage.saveRecords(records)
            return true
        } catch {
            diagnostics.lastError = "pairings.json not written: \(error)"
            return false
        }
    }

    /// Writes the cache and the outbox. While the phone is locked the write fails, and the model keeps them in memory.
    private func saveReviewFiles() {
        guard let storage, let id = selectedID, !store.isDemo else { return }
        do {
            try storage.saveCache(store.cache, id)
            try storage.saveOutbox(store.outbox, id)
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
