import Foundation
import LastideKit

/// The files in the App Group container `group.dev.lastide.app`, under its folder `Lastide` (design Table 14).
///
/// The app, the notification service extension and the widget compile this file. Each file has one writer:
/// `pairings.json` and `settings.json` the app, `push/` and `extension-run.json` the extension, `counts/` the app, and
/// `widget-push.json` the widget. Every file uses the class `completeUntilFirstUserAuthentication`, so a locked phone
/// reads it after the first unlock, and every file is excluded from backup.
struct GroupFiles: Sendable {
    /// The App Group of the three bundles.
    static let groupID = "group.dev.lastide.app"

    /// iOS gave no container, so the build lacks the App Group entitlement.
    struct MissingContainer: Error, CustomStringConvertible {
        var description: String { "the App Group container \(GroupFiles.groupID) is missing" }
    }

    let directory: URL

    init(directory: URL) { self.directory = directory }

    /// The folder `Lastide` in the App Group container.
    static func shared() throws -> GroupFiles {
        guard let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else {
            throw MissingContainer()
        }
        return GroupFiles(directory: base.appendingPathComponent("Lastide", isDirectory: true))
    }

    var pairingsURL: URL { directory.appendingPathComponent("pairings.json") }
    var settingsURL: URL { directory.appendingPathComponent("settings.json") }
    var extensionRunURL: URL { directory.appendingPathComponent("extension-run.json") }
    var widgetPushURL: URL { directory.appendingPathComponent("widget-push.json") }
    var pushDirectory: URL { directory.appendingPathComponent("push", isDirectory: true) }
    var countsDirectory: URL { directory.appendingPathComponent("counts", isDirectory: true) }
    func pushURL(_ id: PairingID) -> URL { pushDirectory.appendingPathComponent(id.base64url + ".json") }
    func countsURL(_ id: PairingID) -> URL { countsDirectory.appendingPathComponent(id.base64url + ".json") }

    func loadRecords() throws -> [PairingRecord] { try read([PairingRecord].self, pairingsURL) ?? [] }
    func saveRecords(_ records: [PairingRecord]) throws { try write(records, pairingsURL) }

    func loadSettings() throws -> GroupSettings { try read(GroupSettings.self, settingsURL) ?? .standard }
    func saveSettings(_ settings: GroupSettings) throws { try write(settings, settingsURL) }

    func loadPush(_ id: PairingID) throws -> PushState? { try read(PushState.self, pushURL(id)) }
    func savePush(_ state: PushState, _ id: PairingID) throws { try write(state, pushURL(id)) }

    func loadCount(_ id: PairingID) throws -> CountState? { try read(CountState.self, countsURL(id)) }
    func saveCount(_ state: CountState, _ id: PairingID) throws { try write(state, countsURL(id)) }

    func loadExtensionRun() throws -> ExtensionRun? { try read(ExtensionRun.self, extensionRunURL) }
    func saveExtensionRun(_ run: ExtensionRun) throws { try write(run, extensionRunURL) }

    func loadWidgetPush() throws -> WidgetPushState? { try read(WidgetPushState.self, widgetPushURL) }
    func saveWidgetPush(_ state: WidgetPushState) throws { try write(state, widgetPushURL) }

    /// The newest waiting count of each pairing that has a push or a counts record.
    func waitingCounts() throws -> [WaitingCount] {
        var ids = Set<String>()
        for folder in [pushDirectory, countsDirectory] where FileManager.default.fileExists(atPath: folder.path) {
            for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) where name.hasSuffix(".json") {
                ids.insert(String(name.dropLast(".json".count)))
            }
        }
        return try ids.sorted().compactMap { text in
            guard let id = try? PairingID(base64url: text) else { return nil }
            return WaitingCount.newest(push: try loadPush(id), count: try loadCount(id))
        }
    }

    /// Deletes the push and counts records of one PC.
    func deleteFiles(of id: PairingID) throws {
        for url in [pushURL(id), countsURL(id)] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Reads one JSON file, or nil when the file does not exist yet.
    private func read<T: Decodable>(_ type: T.Type, _ url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try GroupRecord.decode(type, Data(contentsOf: url))
    }

    private func write<T: Encodable>(_ value: T, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try GroupRecord.encode(value)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
}

extension Data {
    /// Lowercase hex, as `push-token` and `widget-push.json` write a token.
    var lowercaseHex: String { map { String(format: "%02x", $0) }.joined() }

    /// Reads lowercase hex of 16 to 100 bytes, or nil.
    init?(hexToken text: String) {
        let bytes = Array(text.utf8)
        guard bytes.count % 2 == 0, (32...200).contains(bytes.count) else { return nil }
        var data = Data(capacity: bytes.count / 2)
        var index = 0
        while index < bytes.count {
            guard let pair = UInt8(String(decoding: bytes[index..<index + 2], as: UTF8.self), radix: 16) else { return nil }
            data.append(pair)
            index += 2
        }
        self = data
    }
}
