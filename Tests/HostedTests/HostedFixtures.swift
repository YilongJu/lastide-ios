import Foundation
@testable import Lastide
import LastideKit
import Security
import XCTest

// Fakes and fixtures of the hosted tests. Every value is made up, or comes from the push vector of protocol 10.5.

private final class HostedBundleToken {}

/// The push vector, and a pairing record, phone key and token that open its envelopes.
struct PushVector {
    let object: [String: Any]
    let record: PairingRecord
    let phoneKey: Data
    let token = Data((100..<132).map { UInt8($0) })

    init() throws {
        let url = try XCTUnwrap(Bundle(for: HostedBundleToken.self).url(forResource: "lastide-push-v1", withExtension: "json",
                                                                         subdirectory: "Vectors"))
        object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let keys = try XCTUnwrap(object["keys"] as? [String: Any])
        let ids = try XCTUnwrap(object["ids"] as? [String: Any])
        phoneKey = try Self.hex(keys["phonePrivateKey"])
        let json: [String: Any] = [
            "pairingId": Base64URL.encode(try Self.hex(ids["pairingId"])),
            "relayOrigin": "https://relay.example",
            "pcKey": Base64URL.encode(try Self.hex(keys["pcPublicKey"])),
            "pcName": "My PC",
            "pcSchema": 3,
            "phoneId": Base64URL.encode(try Self.hex(ids["phoneId"])),
            "pairedAt": 1_794_992_400_000,
            "lastSentSeq": 1,
            "lastRecvSeq": 1,
            "features": ["mailbox", "push"],
        ]
        record = try JSONDecoder().decode(PairingRecord.self, from: JSONSerialization.data(withJSONObject: json))
    }

    var id: PairingID { record.pairingId }

    func entry(_ name: String) throws -> [String: Any] { try XCTUnwrap(object[name] as? [String: Any]) }

    /// `lastide.e` of the notice or the count update.
    func e(_ name: String) throws -> String { try XCTUnwrap(entry(name)["e"] as? String) }

    func envelope(_ name: String) throws -> Data { try Self.hex(entry(name)["envelope"]) }

    func seq(_ name: String) throws -> UInt64 { UInt64(try XCTUnwrap(entry(name)["seq"] as? Int)) }

    /// The text the extension sets for the vector's notice with the rule text shown.
    var shownText: NotificationText {
        NotificationText(title: "My PC", subtitle: "", body: "Name each branch after its ticket.", category: "PROPOSED_RULE")
    }

    static func hex(_ value: Any?) throws -> Data {
        let text = try XCTUnwrap(value as? String)
        var bytes = Data(capacity: text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            bytes.append(try XCTUnwrap(UInt8(text[index..<next], radix: 16)))
            index = next
        }
        return bytes
    }
}

/// A new empty folder under the test's temporary directory.
func temporaryFolder(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("lastide-\(name)-\(UUID().uuidString)",
                                                                             isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

let testFacts = DeviceFacts(deviceName: "iPhone", model: "iPhone17,3", app: AppInfo(version: "0.1.0", build: 1),
                            relayOrigins: ["https://relay.example"], pushEnvironment: .sandbox)

/// Secrets in memory, for the tests that do not need the Keychain.
final class MemorySecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    func save(_ value: Data, account: String) throws { lock.withLock { items[account] = value } }
    func load(account: String) throws -> Data? { lock.withLock { items[account] } }
    func delete(account: String) throws { lock.withLock { items[account] = nil } }
    func allAccounts() throws -> [String] { lock.withLock { Array(items.keys) } }
}

/// App files that throw the file protection error, as on a phone locked since the restart (design Table 21, U9).
struct LockedFiles: AppFiles {
    private var locked: Error { CocoaError(.fileReadNoPermission) }
    func loadPreferences() throws -> Preferences { throw locked }
    func savePreferences(_ preferences: Preferences) throws { throw locked }
    func loadCache(_ id: PairingID) throws -> ReviewCache { throw locked }
    func saveCache(_ cache: ReviewCache, _ id: PairingID) throws { throw locked }
    func loadOutbox(_ id: PairingID) throws -> [OutboxEntry] { throw locked }
    func saveOutbox(_ outbox: [OutboxEntry], _ id: PairingID) throws { throw locked }
    func deleteFiles(of id: PairingID) throws { throw locked }
}

@MainActor
final class FakeSocket: RelaySocket {
    private(set) var texts: [String] = []
    private(set) var binaries: [Data] = []
    private(set) var closed = false
    func send(text: String) { texts.append(text) }
    func send(binary: Data) { binaries.append(binary) }
    func close() { closed = true }
}

@MainActor
final class FakeSocketFactory: RelaySocketFactory {
    private(set) var sockets: [FakeSocket] = []
    private var handlers: [@MainActor (SocketEvent) -> Void] = []

    func open(url: URL, onEvent: @escaping @MainActor (SocketEvent) -> Void) -> RelaySocket {
        let socket = FakeSocket()
        sockets.append(socket)
        handlers.append(onEvent)
        return socket
    }

    /// Delivers one event to the newest socket.
    func deliver(_ event: SocketEvent) { handlers.last?(event) }
}

/// A `/frames` poster that records each request and can hold the answer until the test releases it.
@MainActor
final class FakeFramesPoster: FramesPoster {
    private(set) var requests: [FramesRequest] = []
    var answer: FramesAnswer = .stored(seq: 1)
    var holds = false
    private var waiting: CheckedContinuation<Void, Never>?

    func post(_ request: FramesRequest) async -> FramesAnswer {
        requests.append(request)
        if holds { await withCheckedContinuation { waiting = $0 } }
        return answer
    }

    func release() {
        waiting?.resume()
        waiting = nil
    }
}

@MainActor
final class FakeNotices: LocalNotices {
    private(set) var posted: [String] = []
    private(set) var badges: [Int] = []
    func post(_ body: String) { posted.append(body) }
    func setBadge(_ count: Int) { badges.append(count) }
}

@MainActor
final class FakeAccess: NotificationAccess {
    var permission = NotificationPermission.on
    func read() async -> (NotificationPermission, PreviewSetting) { (permission, .always) }
    func request() async -> NotificationPermission { permission }
}

@MainActor
final class FakeWidgets: WidgetPushSource {
    private(set) var reloads = 0
    func current(group: GroupFiles?) async -> (token: Data?, widgets: Int) { (nil, 0) }
    func reloadTimelines() { reloads += 1 }
}

/// A model on fakes, with its fakes.
@MainActor
struct ModelHarness {
    let sockets: FakeSocketFactory
    let frames: FakeFramesPoster
    let notices: FakeNotices
    let access: FakeAccess
    let widgets: FakeWidgets
    let model: AppModel

    init() throws {
        sockets = FakeSocketFactory()
        frames = FakeFramesPoster()
        notices = FakeNotices()
        access = FakeAccess()
        widgets = FakeWidgets()
        let services = ModelServices(sockets: sockets, frames: frames, notices: notices, access: access, widgets: widgets,
                                     attester: UnsupportedAttester())
        model = try AppModel(facts: testFacts, services: services, now: currentTimeMs)
    }
}

/// Keychain helpers for the move tests. Every call names its access group.
enum TestKeychain {
    static func add(service: String, account: String, group: String, value: Data) -> OSStatus {
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: group,
            kSecValueData as String: value,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        return SecItemAdd(item as CFDictionary, nil)
    }

    /// The value and the accessibility of one item in one group, or nil.
    static func read(service: String, account: String, group: String) -> (Data, String)? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: group,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let attributes = result as? [String: Any], let data = attributes[kSecValueData as String] as? Data
        else { return nil }
        return (data, attributes[kSecAttrAccessible as String] as? String ?? "")
    }

    /// The access group of one item, found without naming a group.
    static func group(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return (result as? [String: Any])?[kSecAttrAccessGroup as String] as? String
    }

    /// Deletes every item of the service in every group.
    static func deleteAll(service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// The App Group, which the host app holds and which lies outside the shared Keychain group. The tests use it as the
/// old group of an item, as the app's own group held the items before phase 7.
let outsideGroup = "group.dev.lastide.app"
