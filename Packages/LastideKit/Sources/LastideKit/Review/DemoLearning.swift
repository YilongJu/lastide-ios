import Foundation

/// The learning lists of demo mode (protocol section 8.1): `Resources/Demo/learning.json`, which
/// `scripts/relay-check/make-demo-learning.mjs` in the Lastide workspace writes from the demo room's own model. So demo
/// mode shows the same numbers and lists as the demo room. No row holds words, and demo mode reads none.
public struct DemoLearning: Sendable {
    /// One list of the file, with every row.
    public struct List: Hashable, Sendable, Decodable {
        public let subject: LearningSubject
        public let value: Int
        public let total: Int
        public let leftOut: LearningLeftOut
        public let head: LearningHead?
        public let rows: [LearningRow]
        public let listHash: String
    }

    private struct File: Decodable {
        let storeVersion: Int
        let asOf: Int
        let thresholds: LearningThresholds
        let lists: [List]
    }

    public let storeVersion: Int
    /// The demo's clock: the time the lists were built, which is also the counts fixture's `sentAt`.
    public let asOf: Int
    public let thresholds: LearningThresholds
    public let lists: [LearningSubject: List]

    /// Loads `learning.json` and checks each list as a page of the schema would be checked.
    public static func load() throws -> DemoLearning {
        let file = try JSONDecoder().decode(File.self, from: DemoFixtures.plaintext("learning"))
        var lists: [LearningSubject: List] = [:]
        for list in file.lists {
            guard lists[list.subject] == nil else { throw DemoFixtureError.duplicateList(list.subject.kind.rawValue) }
            guard list.total == list.rows.count, list.value == list.total + list.leftOut.older else {
                throw DemoFixtureError.listDoesNotAddUp(list.subject.kind.rawValue)
            }
            lists[list.subject] = list
        }
        let demo = DemoLearning(storeVersion: file.storeVersion, asOf: file.asOf, thresholds: file.thresholds, lists: lists)
        for subject in lists.keys {
            var from = 0
            repeat {
                let page = demo.page(LearningRequest(id: makeMessageID(), sentAt: file.asOf, subject: subject, from: from,
                                                     listHash: from == 0 ? nil : lists[subject]!.listHash))
                try SyncMessage.learningPage(page).validate()
                from = page.next ?? -1
            } while from > 0
        }
        return demo
    }

    /// The page that answers one request, with 50 rows at most, as the PC pages a list (protocol 7.6).
    public func page(_ request: LearningRequest) -> LearningPage {
        func empty(_ state: LearningPageState) -> LearningPage {
            LearningPage(id: makeMessageID(), sentAt: asOf, requestId: request.id, subject: request.subject, state: state,
                         storeVersion: storeVersion, asOf: asOf, value: 0, total: 0,
                         leftOut: LearningLeftOut(untraced: 0, older: 0, afterThisWeek: 0), from: request.from, next: nil,
                         listHash: nil, thresholds: thresholds, head: nil, rows: [])
        }
        guard let list = lists[request.subject] else { return empty(.gone) }
        if (request.from > 0 && request.listHash != list.listHash) || request.from > list.total { return empty(.changed) }
        let rows = Array(list.rows.dropFirst(request.from).prefix(50))
        let end = request.from + rows.count
        return LearningPage(id: makeMessageID(), sentAt: asOf, requestId: request.id, subject: request.subject, state: .ok,
                            storeVersion: storeVersion, asOf: asOf, value: list.value, total: list.total,
                            leftOut: list.leftOut, from: request.from, next: end < list.total ? end : nil,
                            listHash: list.listHash, thresholds: thresholds, head: list.head, rows: rows)
    }
}
