import Foundation
@testable import Lastide
import LastideKit
import UIKit
import UserNotifications
import XCTest

/// The delegate calls each completion handler that UIKit hands it on the main thread, exactly once.
///
/// UIKit's handler for a notification response asserts the main thread. TestFlight build 5 called it from a Swift
/// concurrency thread, so every tap on a notice and every lock-screen Approve or Delete stopped the app with SIGABRT.
/// These tests call the delegate through its Objective-C requirement, as iOS does, and record where the handler runs.
@MainActor
final class DelegateThreadTests: XCTestCase {
    /// iOS calls `didReceive` on a queue of its own. Each case calls the delegate from a background queue with a real
    /// `UNNotificationResponse`: the tap on the notice, Approve and Delete.
    func testTheResponseHandlerRunsOnceOnTheMainThreadAfterTheAction() async throws {
        let vector = try PushVector()
        for identifier in [UNNotificationDefaultActionIdentifier, PushText.approveAction, PushText.deleteAction] {
            let delegate = AppDelegate()
            let actions = ActionRecord()
            let record = CompletionRecord()
            delegate.notificationAction = { identifier, envelope, shown in
                actions.calls.append(ActionRecord.Call(identifier: identifier, envelope: envelope, shown: shown))
                // The handler must wait for the action, so it must not run before the action ends.
                await Task.yield()
                actions.ended = true
                record.actionEnded()
            }
            let response = try Self.response(action: identifier, vector: vector)
            let done = expectation(description: "completion handler of \(identifier)")
            let call = Unchecked(value: (delegate as UNUserNotificationCenterDelegate, response, done))
            DispatchQueue.global(qos: .userInitiated).async {
                let (target, response, done) = call.value
                record.calledFrom(main: Thread.isMainThread)
                target.userNotificationCenter?(UNUserNotificationCenter.current(), didReceive: response,
                                               withCompletionHandler: {
                    record.completed(main: Thread.isMainThread)
                    done.fulfill()
                })
            }
            await fulfillment(of: [done], timeout: 10)
            // A second call of the handler would arrive in this time.
            try await Task.sleep(for: .milliseconds(300))

            XCTAssertEqual(record.callerOnMain, [false], "\(identifier): the test calls the delegate off the main thread")
            XCTAssertEqual(record.handlerOnMain, [true],
                           "\(identifier): the completion handler must run once, on the main thread")
            XCTAssertTrue(record.handlerAfterAction, "\(identifier): the completion handler ran before the action ended")
            XCTAssertEqual(actions.calls, [ActionRecord.Call(identifier: identifier, envelope: try vector.envelope("notice"),
                                                             shown: vector.shownText)],
                           "\(identifier): the action runs once with the identifier, envelope and text of the response")
            XCTAssertTrue(actions.ended)
        }
    }

    /// A response whose payload holds no envelope still reaches the action with a nil envelope, and the handler still
    /// runs once on the main thread.
    func testAResponseWithoutAnEnvelopeStillCallsTheHandlerOnce() async throws {
        let vector = try PushVector()
        let delegate = AppDelegate()
        let actions = ActionRecord()
        let record = CompletionRecord()
        delegate.notificationAction = { identifier, envelope, shown in
            actions.calls.append(ActionRecord.Call(identifier: identifier, envelope: envelope, shown: shown))
        }
        let response = try Self.response(action: PushText.approveAction, vector: vector, userInfo: [:])
        let done = expectation(description: "completion handler")
        let call = Unchecked(value: (delegate as UNUserNotificationCenterDelegate, response, done))
        DispatchQueue.global(qos: .userInitiated).async {
            let (target, response, done) = call.value
            target.userNotificationCenter?(UNUserNotificationCenter.current(), didReceive: response,
                                           withCompletionHandler: {
                record.completed(main: Thread.isMainThread)
                done.fulfill()
            })
        }
        await fulfillment(of: [done], timeout: 10)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(record.handlerOnMain, [true])
        XCTAssertEqual(actions.calls.map(\.envelope), [nil])
    }

    /// UIKit calls the background push method on the main thread. Its fetch handler must run there too, once. The test
    /// host has no launch environment, so the runtime answers `failed` without reading a file.
    func testTheFetchHandlerOfABackgroundPushRunsOnceOnTheMainThread() async throws {
        let delegate = AppDelegate()
        let record = CompletionRecord()
        let results = ResultRecord()
        let done = expectation(description: "fetch completion handler")
        (delegate as UIApplicationDelegate).application?(UIApplication.shared, didReceiveRemoteNotification: [:],
                                                         fetchCompletionHandler: { result in
            record.completed(main: Thread.isMainThread)
            results.append(result)
            done.fulfill()
        })
        await fulfillment(of: [done], timeout: 10)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(record.handlerOnMain, [true], "the fetch handler must run once, on the main thread")
        XCTAssertEqual(results.values, [.failed])
    }

    // MARK: Fixtures

    /// A real `UNNotificationResponse` with the vector's notice. iOS gives these classes no public initializer, so the
    /// test makes empty objects through `init(coder:)` with a coder that answers every key with an empty value, then
    /// sets the request and the action by key. Only a test target may do this.
    private static func response(action: String, vector: PushVector,
                                 userInfo: [AnyHashable: Any]? = nil) throws -> UNNotificationResponse {
        let content = UNMutableNotificationContent()
        let shown = vector.shownText
        content.title = shown.title
        content.subtitle = shown.subtitle
        content.body = shown.body
        content.categoryIdentifier = shown.category
        let notice: [AnyHashable: Any] = ["lastide": ["v": 1, "e": try vector.e("notice")]]
        content.userInfo = userInfo ?? notice
        let request = UNNotificationRequest(identifier: "lastide-test-notice", content: content, trigger: nil)
        let notification = try XCTUnwrap(UNNotification(coder: EmptyCoder(requiringSecureCoding: false)))
        notification.setValue(request, forKey: "request")
        let response = try XCTUnwrap(UNNotificationResponse(coder: EmptyCoder(requiringSecureCoding: false)))
        response.setValue(notification, forKey: "notification")
        response.setValue(action, forKey: "actionIdentifier")
        XCTAssertEqual(response.actionIdentifier, action)
        XCTAssertEqual(response.notification.request.content.body, shown.body)
        return response
    }
}

/// A coder that answers every key with an empty value, so `init(coder:)` makes an empty object.
private final class EmptyCoder: NSKeyedArchiver {
    override func decodeObject(forKey _: String) -> Any { "" }
    override func decodeInt64(forKey _: String) -> Int64 { 0 }
    override func decodeInt32(forKey _: String) -> Int32 { 0 }
    override func decodeInteger(forKey _: String) -> Int { 0 }
    override func decodeBool(forKey _: String) -> Bool { false }
    override func decodeDouble(forKey _: String) -> Double { 0 }
}

/// Each action the delegate ran.
@MainActor
private final class ActionRecord {
    struct Call: Equatable {
        let identifier: String
        let envelope: Data?
        let shown: NotificationText
    }

    var calls: [Call] = []
    var ended = false
}

/// Where the delegate was called from and where each completion handler ran, from any thread.
private final class CompletionRecord: @unchecked Sendable {
    private let lock = NSLock()
    private var caller: [Bool] = []
    private var handler: [Bool] = []
    private var actionDone = false
    private var afterAction = true

    func calledFrom(main: Bool) { lock.withLock { caller.append(main) } }
    func actionEnded() { lock.withLock { actionDone = true } }

    func completed(main: Bool) {
        lock.withLock {
            handler.append(main)
            if !actionDone { afterAction = false }
        }
    }

    var callerOnMain: [Bool] { lock.withLock { caller } }
    var handlerOnMain: [Bool] { lock.withLock { handler } }
    var handlerAfterAction: Bool { lock.withLock { actionDone && afterAction } }
}

/// The results a fetch handler received.
private final class ResultRecord: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [UIBackgroundFetchResult] = []

    func append(_ result: UIBackgroundFetchResult) { lock.withLock { stored.append(result) } }
    var values: [UIBackgroundFetchResult] { lock.withLock { stored } }
}

/// Carries values that are not Sendable to the background queue, as iOS hands them to the delegate.
private struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
}
