import Foundation
import LastideKit

/// The settings the person sets on the phone, kept in the app's own container.
struct Preferences: Codable, Equatable, Sendable {
    /// When the person agreed to the disclosure `outside-ai-v1`, or nil before the first agreement.
    var disclosureAcceptedAt: Int?
    /// The pairing id the screens show.
    var selectedPairingID: PairingID?
    /// When the app asked "Get a notification when a rule waits for your review?", or nil before it asked (design 6.3).
    var notificationQuestionAt: Int?
}

/// The files in the app's own container (protocol Table 8). The App Group holds the rest (`GroupFiles`).
/// A test hands the model a stub, so a launch that cannot read them can be checked (design Table 21, U9).
protocol AppFiles: Sendable {
    func loadPreferences() throws -> Preferences
    func savePreferences(_ preferences: Preferences) throws
    func loadCache(_ id: PairingID) throws -> ReviewCache
    func saveCache(_ cache: ReviewCache, _ id: PairingID) throws
    func loadOutbox(_ id: PairingID) throws -> [OutboxEntry]
    func saveOutbox(_ outbox: [OutboxEntry], _ id: PairingID) throws
    /// Deletes the cache and the outbox of one PC.
    func deleteFiles(of id: PairingID) throws
}

/// The app's files in its Application Support folder.
///
/// `preferences.json` uses the class `completeUntilFirstUserAuthentication`. The cache and the outbox of each PC use
/// `complete`, so they open only while the phone is unlocked. Every file is excluded from backup, and the flag is set
/// again after each write, because an atomic replace can reset it.
struct FileStorage: AppFiles {
    let directory: URL

    enum Protection: Sendable { case untilFirstUnlock, complete }

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// The app's Application Support folder.
    static func appSupportDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil,
                                               create: true)
        return base.appendingPathComponent("Lastide", isDirectory: true)
    }

    /// Where builds before phase 7 kept `pairings.json`. The first phase 7 launch moves it to the App Group (design 6.2).
    var oldPairingsURL: URL { directory.appendingPathComponent("pairings.json") }
    var preferencesURL: URL { directory.appendingPathComponent("preferences.json") }
    func cacheURL(_ id: PairingID) -> URL { directory.appendingPathComponent("cache-\(id.base64url).json") }
    func outboxURL(_ id: PairingID) -> URL { directory.appendingPathComponent("outbox-\(id.base64url).json") }

    func loadPreferences() throws -> Preferences { try read(Preferences.self, preferencesURL) ?? Preferences() }
    func savePreferences(_ preferences: Preferences) throws { try write(preferences, preferencesURL, .untilFirstUnlock) }

    func loadCache(_ id: PairingID) throws -> ReviewCache { try read(ReviewCache.self, cacheURL(id)) ?? ReviewCache() }
    func saveCache(_ cache: ReviewCache, _ id: PairingID) throws { try write(cache, cacheURL(id), .complete) }

    func loadOutbox(_ id: PairingID) throws -> [OutboxEntry] { try read([OutboxEntry].self, outboxURL(id)) ?? [] }
    func saveOutbox(_ outbox: [OutboxEntry], _ id: PairingID) throws { try write(outbox, outboxURL(id), .complete) }

    func deleteFiles(of id: PairingID) throws {
        for url in [cacheURL(id), outboxURL(id)] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Reads one JSON file, or nil when the file does not exist yet.
    private func read<T: Decodable>(_ type: T.Type, _ url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    private func write<T: Encodable>(_ value: T, _ url: URL, _ protection: Protection) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        let options: Data.WritingOptions = protection == .complete
            ? [.atomic, .completeFileProtection]
            : [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        try data.write(to: url, options: options)
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
}

/// The one-time moves of the first phase 7 launch (design section 6.2).
enum StorageMove {
    /// The stored data does not decode, so the move stops before it deletes anything.
    struct Failure: Error, CustomStringConvertible {
        let detail: String
        var description: String { "the pairings move stopped: \(detail)" }
    }

    /// Copies `pairings.json` from Application Support into the App Group, checks that the copy decodes, then deletes
    /// the old file. Returns true when it moved a file. A copy left by an interrupted move is checked and kept.
    static func movePairings(from oldURL: URL, to group: GroupFiles) throws -> Bool {
        guard FileManager.default.fileExists(atPath: oldURL.path) else { return false }
        let old = try JSONDecoder().decode([PairingRecord].self, from: Data(contentsOf: oldURL))
        if FileManager.default.fileExists(atPath: group.pairingsURL.path) {
            let copy = try group.loadRecords()
            guard Set(copy.map(\.pairingId)).isSuperset(of: old.map(\.pairingId)) else {
                throw Failure(detail: "both files hold pairings, and the App Group copy lacks some")
            }
        } else {
            try group.saveRecords(old)
            guard try group.loadRecords() == old else { throw Failure(detail: "the copy reads back differently") }
        }
        try FileManager.default.removeItem(at: oldURL)
        return true
    }
}
