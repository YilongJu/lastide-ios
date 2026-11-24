import Foundation

/// The bundled synthetic messages of demo mode (section 8.1).
public struct DemoFixtures: Sendable {
    /// `Resources/Demo/queue.json`.
    public let queue: QueueSnapshot
    /// `Resources/Demo/library.json`.
    public let library: LibrarySnapshot
    /// `Resources/Demo/counts.json`.
    public let counts: Counts

    /// Loads and checks the three fixtures against section 7.3.
    public static func load() throws -> DemoFixtures {
        guard case .queue(let queue) = try SyncMessage.decode(try plaintext("queue")),
              case .library(let library) = try SyncMessage.decode(try plaintext("library")),
              case .counts(let counts) = try SyncMessage.decode(try plaintext("counts"))
        else { throw DemoFixtureError.wrongType }
        return DemoFixtures(queue: queue, library: library, counts: counts)
    }

    /// The plaintext of one fixture file.
    public static func plaintext(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Demo") else {
            throw DemoFixtureError.missing(name)
        }
        return try Data(contentsOf: url)
    }
}

/// Why a demo fixture could not load.
public enum DemoFixtureError: Error, Equatable, Sendable {
    case missing(String)
    case wrongType
    /// `learning.json` holds two lists of one subject.
    case duplicateList(String)
    /// A list's number differs from its rows and its older items.
    case listDoesNotAddUp(String)
}
