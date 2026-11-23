import Foundation
@testable import LastideKit
import XCTest

/// The protocol amendments the phone sees: counters that the PC sends as null (section 7.3), the `desktopOnly` sentence of
/// a rule (Table 22), the text rule of section 7.4, check 7, and schema revision 2: the drafting run counts, the waiting
/// import principles and the review comment evidence item.
final class AmendmentTests: XCTestCase {
    private let draft1 = Target(targetType: .draft, id: "d-0001")

    private func countsJSON(_ fields: String) -> String {
        #"{"type":"counts","id":"\#(sampleID)","sentAt":1,"schema":1,"storeVersion":42,\#(fields),"weeks":[]}"#
    }

    private let nullCounts = #""repeatCorrectionsThisWeek":null,"repeatCorrectionsLastWeek":null,"rulesApproved":2,"violationsThisWeek":null,"draftsToday":1,"draftCap":null"#

    func testCountsTakeNullForTheCountsThePCDoesNotMeasure() throws {
        let message = try decode(countsJSON(nullCounts))
        guard case .counts(let counts) = message else { return XCTFail("not a counts message") }
        XCTAssertNil(counts.repeatCorrectionsThisWeek as Int?)
        XCTAssertNil(counts.repeatCorrectionsLastWeek as Int?)
        XCTAssertNil(counts.violationsThisWeek as Int?)
        XCTAssertNil(counts.draftCap as Int?)
        XCTAssertEqual(counts.rulesApproved, 2)
        XCTAssertEqual(counts.draftsToday, 1)
        let encoded = String(decoding: try JSONEncoder().encode(counts), as: UTF8.self)
        for name in ["repeatCorrectionsThisWeek", "repeatCorrectionsLastWeek", "violationsThisWeek", "draftCap"] {
            XCTAssertTrue(encoded.contains(#""\#(name)":null"#), "\(name) is written as null, never left out")
        }
    }

    func testCountsStillRefuseAMissingKeyANegativeCountAndNullWhereTheSchemaHasNoNull() throws {
        let missing = nullCounts.replacingOccurrences(of: #","draftCap":null"#, with: "")
        XCTAssertThrowsError(try decode(countsJSON(missing)), "a nullable field must still be present")
        let negative = nullCounts.replacingOccurrences(of: #""draftCap":null"#, with: #""draftCap":-1"#)
        XCTAssertThrowsError(try decode(countsJSON(negative)))
        let nullApproved = nullCounts.replacingOccurrences(of: #""rulesApproved":2"#, with: #""rulesApproved":null"#)
        XCTAssertThrowsError(try decode(countsJSON(nullApproved)), "rulesApproved is always measured")
        let nullToday = nullCounts.replacingOccurrences(of: #""draftsToday":1"#, with: #""draftsToday":null"#)
        XCTAssertThrowsError(try decode(countsJSON(nullToday)), "draftsToday is always measured")
    }

    func testRevisionTwoCountsCarryTheDraftingRunsAndTheWaitingImportAndRevisionOneCountsLeaveThemOut() throws {
        let two = #""repeatCorrectionsThisWeek":null,"repeatCorrectionsLastWeek":null,"rulesApproved":2,"violationsThisWeek":null,"draftsToday":1,"draftCap":null,"draftingRunsToday":3,"draftingRunCap":20,"importRulesWaiting":12"#
        guard case .counts(let counts) = try decode(countsJSON(two)) else { return XCTFail("not a counts message") }
        XCTAssertEqual(counts.draftingRunsToday, 3)
        XCTAssertEqual(counts.draftingRunCap, 20)
        XCTAssertEqual(counts.importRulesWaiting, 12)
        XCTAssertNil(counts.draftCap as Int?, "drafts have no cap of their own; the runs have one")
        guard case .counts(let one) = try decode(countsJSON(nullCounts)) else { return XCTFail("not a counts message") }
        XCTAssertNil(one.draftingRunsToday)
        XCTAssertNil(one.draftingRunCap)
        XCTAssertNil(one.importRulesWaiting)
        let encoded = String(decoding: try JSONEncoder().encode(one), as: UTF8.self)
        XCTAssertFalse(encoded.contains("draftingRunsToday"), "a revision 1 message stays as it came")
        let negative = two.replacingOccurrences(of: #""importRulesWaiting":12"#, with: #""importRulesWaiting":-1"#)
        XCTAssertThrowsError(try decode(countsJSON(negative)))
        XCTAssertEqual(LastideProtocol.schemaRevision, 3, "revision 3 adds count-update (protocol 7.1)")
        XCTAssertEqual(ReviewText.importWaiting(12), "An import of 12 rules waits on your PC.")
        XCTAssertEqual(ReviewText.importWaiting(1), "An import of 1 rule waits on your PC.")
        XCTAssertEqual(ReviewText.draftingRuns(3, cap: 20), "3 of 20")
    }

    func testAReviewCommentEvidenceItemHasNoAgentAndCarriesItsLabel() throws {
        let comment = #"{"id":"2","at":1794319200000,"projectName":"northwind-reports","agent":null,"signal":"reviewComment","commentLabel":"C7"}"#
        let draft = draftJSON().replacingOccurrences(of: #""signal":"typedTurn"}]"#, with: #""signal":"typedTurn"},"# + comment + "]")
        guard case .queue(let queue) = try decode(queueJSON(storeVersion: 42, drafts: [draft])) else { return XCTFail("not a queue message") }
        let item = queue.drafts[0].evidence[1]
        XCTAssertNil(item.agent)
        XCTAssertEqual(item.commentLabel, "C7")
        XCTAssertEqual(ReviewText.reviewComment("C7"), "Review comment C7")
        XCTAssertEqual(queue.drafts[0].evidence[0].agent, .claudeCode)
        let encoded = String(decoding: try JSONEncoder().encode(item), as: UTF8.self)
        XCTAssertTrue(encoded.contains(#""agent":null"#) && encoded.contains(#""commentLabel":"C7""#))
        for (name, bad) in [
            ("no label", comment.replacingOccurrences(of: #","commentLabel":"C7""#, with: "")),
            ("another signal", comment.replacingOccurrences(of: #""signal":"reviewComment""#, with: #""signal":"typedTurn""#)),
            ("a label of another shape", comment.replacingOccurrences(of: #""C7""#, with: #""7""#)),
            ("a missing agent", comment.replacingOccurrences(of: #""agent":null,"#, with: "")),
        ] {
            let broken = draftJSON().replacingOccurrences(of: #""signal":"typedTurn"}]"#, with: #""signal":"typedTurn"},"# + bad + "]")
            XCTAssertThrowsError(try decode(queueJSON(storeVersion: 42, drafts: [broken])), name)
        }
    }

    func testRuleViolationCountersTakeNull() throws {
        let rule = ruleJSON().replacingOccurrences(of: #""violationsSinceApproval":1,"violationsLast30Days":1"#,
                                                   with: #""violationsSinceApproval":null,"violationsLast30Days":null"#)
        let message = try decode(libraryJSON(storeVersion: 42, rules: [rule]))
        guard case .library(let library) = message else { return XCTFail("not a library message") }
        XCTAssertNil(library.rules[0].violationsSinceApproval as Int?)
        XCTAssertNil(library.rules[0].violationsLast30Days as Int?)
        let encoded = String(decoding: try JSONEncoder().encode(library.rules[0]), as: UTF8.self)
        XCTAssertTrue(encoded.contains(#""violationsSinceApproval":null"#))
        XCTAssertTrue(encoded.contains(#""violationsLast30Days":null"#))
        let nullCorrections = rule.replacingOccurrences(of: #""correctionsBeforeApproval":4"#, with: #""correctionsBeforeApproval":null"#)
        XCTAssertThrowsError(try decode(libraryJSON(storeVersion: 42, rules: [nullCorrections])),
                             "correctionsBeforeApproval comes from the receipts and is never null")
    }

    func testADesktopOnlyRuleReadsChangeOnYourPCAndADraftKeepsApprove() throws {
        var store = ReviewStore(cache: ReviewCache(), outbox: [])
        store.apply(try decode(queueJSON(storeVersion: 42, drafts: [draftJSON(id: "d-hook", kind: "hook", desktopOnly: true)])))
        store.apply(try decode(libraryJSON(storeVersion: 42, rules: [ruleJSON(id: "r-project", desktopOnly: true)])))
        let rule = Target(targetType: .rule, id: "r-project")
        XCTAssertEqual(store.status(of: rule).displayText, "Change this one on your PC")
        XCTAssertEqual(store.status(of: Target(targetType: .draft, id: "d-hook")).displayText, "Approve this one on your PC")
        XCTAssertFalse(store.status(of: rule).allowsActions)
        XCTAssertThrowsError(try store.decide(rule, action: .turnOff, text: nil, scopeOptionId: nil, now: sampleTime)) {
            XCTAssertEqual($0 as? ReviewError, .desktopOnly(.rule))
        }
    }

    func testAPCRefusalOfARuleWithDesktopOnlyReadsChangeOnYourPC() throws {
        var store = ReviewStore(cache: ReviewCache(), outbox: [])
        store.apply(try decode(libraryJSON(storeVersion: 42)))
        let rule = Target(targetType: .rule, id: "r-0007")
        let decision = try store.decide(rule, action: .turnOff, text: nil, scopeOptionId: nil, now: sampleTime)
        let outcome = store.apply(try decode(acknowledgementJSON(decisionId: decision.decisionId, result: "refused",
                                                                 reason: "desktopOnly", storeVersion: 43)))
        XCTAssertEqual(outcome, .refused(rule, .desktopOnly))
        XCTAssertEqual(store.status(of: rule), .refused(.desktopOnly, .rule))
        XCTAssertEqual(store.status(of: rule).displayText, "Change this one on your PC")
    }

    func testTextRuleNamesTheFirstProblemInTheOrderOfCheck7() {
        XCTAssertEqual(TextRule.problem(in: ""), .empty)
        XCTAssertEqual(TextRule.problem(in: " \u{3000} "), .empty)
        XCTAssertEqual(TextRule.problem(in: String(repeating: "\u{200B}", count: 501)), .tooLong, "length before hidden code points")
        XCTAssertEqual(TextRule.problem(in: "a\u{202E}b @x"), .hiddenCodePoint("\u{202E}"), "hidden code points before imports")
        XCTAssertEqual(TextRule.problem(in: "see @x"), .fileImport)
        XCTAssertNil(TextRule.problem(in: "see a@x"))
        XCTAssertNil(TextRule.problem(in: "see @ x"))
        XCTAssertNil(TextRule.problem(in: "Write each date as year, month, day."))
    }

    /// One decision on a fresh store, so each text meets the rule alone.
    private func approve(_ text: String) throws -> Decision {
        var store = ReviewStore(cache: ReviewCache(), outbox: [])
        store.apply(try decode(queueJSON(storeVersion: 42)))
        return try store.decide(draft1, action: .approve, text: text, scopeOptionId: nil, now: sampleTime)
    }

    func testThePhoneRefusesTextThatThePCRefuses() throws {
        let refused: [String: String] = [
            "right-to-left override": "Use \u{202E}sentence case",
            "zero-width space": "Use sentence\u{200B} case",
            "byte order mark": "\u{FEFF}Use sentence case",
            "tag character": "Use sentence case\u{E0041}",
            "word joiner": "Use\u{2060} sentence case",
            "private use": "Use \u{E000} sentence case",
            "unassigned": "Use \u{0378} sentence case",
            "line separator": "Use\u{2028}sentence case",
            "paragraph separator": "Use\u{2029}sentence case",
            "tab": "Use\tsentence case",
            "file import at the start": "@README holds the style",
            "file import after a space": "Follow the notes in @~/.ssh/id_rsa",
            "file import after an ideographic space": "Read\u{3000}@notes.md",
            "spaces only": "   ",
            "ideographic space only": "\u{3000}",
            "501 code points": String(repeating: "x", count: 501),
        ]
        for (name, text) in refused.sorted(by: { $0.key < $1.key }) {
            XCTAssertThrowsError(try approve(text), name) { XCTAssertEqual($0 as? ReviewError, .invalidText, name) }
        }
    }

    func testThePhoneAcceptsTextThatThePCAccepts() throws {
        let accepted: [String: String] = [
            "an at sign inside a word": "Name the retina file icon@2x",
            "an at sign alone": "Meet @ the start of each review",
            "an at sign at the end": "Tag the owner with @",
            "a parenthesis before the at sign": "Name files (@2x) for retina",
            "500 code points": String(repeating: "x", count: 500),
            "600 code points that NFC joins into 300": String(repeating: "e\u{0301}", count: 300),
            "a space at both ends": " Use sentence case ",
        ]
        for (name, text) in accepted.sorted(by: { $0.key < $1.key }) {
            XCTAssertNoThrow(try approve(text), name)
        }
        let joined = try approve(String(repeating: "e\u{0301}", count: 300))
        XCTAssertEqual(joined.text, String(repeating: "\u{E9}", count: 300), "the phone sends the NFC form")
        XCTAssertEqual(joined.text?.unicodeScalars.count, 300)
    }
}
