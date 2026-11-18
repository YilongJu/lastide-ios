import Foundation
import LastideKit

/// The phone's secrets, one Keychain item per pairing and field (protocol section 2.3).
protocol SecretStore: Sendable {
    func save(_ value: Data, account: String) throws
    func load(account: String) throws -> Data?
    func delete(account: String) throws
    /// Every account under the service `lastide.pairing`.
    func allAccounts() throws -> [String]
}

/// The Keychain account names of one pairing: `<pairing id>.key` and `<pairing id>.token`.
enum SecretAccount {
    static func key(_ id: PairingID) -> String { id.base64url + ".key" }
    static func token(_ id: PairingID) -> String { id.base64url + ".token" }
    /// The pairing id an account name starts with.
    static func pairingID(of account: String) -> String { String(account.prefix { $0 != "." }) }
}

/// The settings the person sets on the phone, kept beside `pairings.json`.
struct Preferences: Codable, Equatable, Sendable {
    /// When the person agreed to the disclosure `outside-ai-v1`, or nil before the first agreement.
    var disclosureAcceptedAt: Int?
    /// The pairing id the screens show.
    var selectedPairingID: PairingID?
}

/// The app's files in its container (protocol Table 8).
///
/// `pairings.json` and `preferences.json` use the class `completeUntilFirstUserAuthentication`. The cache and the
/// outbox of each PC use `complete`, so they open only while the phone is unlocked. Every file is excluded from backup,
/// and the flag is set again after each write, because an atomic replace can reset it.
struct FileStorage: Sendable {
    let directory: URL

    enum Protection: Sendable { case untilFirstUnlock, complete }

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// The app's Application Support folder.
    static func appSupport() throws -> FileStorage {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil,
                                               create: true)
        return try FileStorage(directory: base.appendingPathComponent("Lastide", isDirectory: true))
    }

    var pairingsURL: URL { directory.appendingPathComponent("pairings.json") }
    var preferencesURL: URL { directory.appendingPathComponent("preferences.json") }
    func cacheURL(_ id: PairingID) -> URL { directory.appendingPathComponent("cache-\(id.base64url).json") }
    func outboxURL(_ id: PairingID) -> URL { directory.appendingPathComponent("outbox-\(id.base64url).json") }

    func loadRecords() throws -> [PairingRecord] { try read([PairingRecord].self, pairingsURL) ?? [] }
    func saveRecords(_ records: [PairingRecord]) throws { try write(records, pairingsURL, .untilFirstUnlock) }

    func loadPreferences() throws -> Preferences { try read(Preferences.self, preferencesURL) ?? Preferences() }
    func savePreferences(_ preferences: Preferences) throws { try write(preferences, preferencesURL, .untilFirstUnlock) }

    func loadCache(_ id: PairingID) throws -> ReviewCache { try read(ReviewCache.self, cacheURL(id)) ?? ReviewCache() }
    func saveCache(_ cache: ReviewCache, _ id: PairingID) throws { try write(cache, cacheURL(id), .complete) }

    func loadOutbox(_ id: PairingID) throws -> [OutboxEntry] { try read([OutboxEntry].self, outboxURL(id)) ?? [] }
    func saveOutbox(_ outbox: [OutboxEntry], _ id: PairingID) throws { try write(outbox, outboxURL(id), .complete) }

    /// Deletes the cache and the outbox of one PC.
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
        #if os(iOS)
        let options: Data.WritingOptions = protection == .complete
            ? [.atomic, .completeFileProtection]
            : [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        try data.write(to: url, options: options)
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        #else
        try data.write(to: url, options: [.atomic])
        #endif
    }
}
