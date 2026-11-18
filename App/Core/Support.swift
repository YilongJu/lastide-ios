import Foundation
import LastideKit

/// The phone's clock in milliseconds since 1970, the unit of every protocol time.
func currentTimeMs() -> Int {
    Int((Date().timeIntervalSince1970 * 1_000).rounded(.down))
}

/// Facts about this phone and this build that the pair request and the diagnostics block carry.
struct DeviceFacts: Sendable, Equatable {
    /// `UIDevice.current.name`, "iPhone" from iOS 16 on.
    let deviceName: String
    /// The hardware model identifier from `utsname.machine`, for example "iPhone17,3".
    let model: String
    /// `CFBundleShortVersionString` and `CFBundleVersion`.
    let app: AppInfo
    /// The relay origins of the build setting `LASTIDE_RELAY_ORIGINS` (protocol section 3.2).
    let relayOrigins: [String]
}

extension DeviceFacts {
    /// Reads the app's version, build and relay origins from the main bundle. A build without them is broken, so the
    /// app stops.
    static func bundleValues(_ bundle: Bundle) -> (app: AppInfo, relayOrigins: [String]) {
        guard let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String, !version.isEmpty else {
            preconditionFailure("Info.plist lacks CFBundleShortVersionString")
        }
        guard let buildText = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              let build = Int(buildText), build >= 1
        else { preconditionFailure("CFBundleVersion is not a whole number of at least 1") }
        guard let originsText = bundle.object(forInfoDictionaryKey: "LASTIDE_RELAY_ORIGINS") as? String else {
            preconditionFailure("Info.plist lacks LASTIDE_RELAY_ORIGINS")
        }
        let origins = originsText.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        precondition(!origins.isEmpty && origins.allSatisfy { !$0.isEmpty },
                     "LASTIDE_RELAY_ORIGINS must hold origins separated by single spaces")
        return (AppInfo(version: version, build: build), origins)
    }
}

/// Short, fixed sentences of the app's own screens. The protocol fixes the ones it names, and the package holds those.
enum AppText {
    static let waitingForPC = "Waiting for your PC"
    static let typeThisCode = "Type this code on your PC"
    static func pairedWith(_ pcName: String) -> String { "Paired with \(pcName)" }
    static let pairAgain = "Pair this phone again"
    static let connecting = "Connecting to the relay"
    static let unreachable = "The relay did not answer. Check the connection, then show a new code on your PC."
    static let pairingTimedOut = "The connection timed out. Show a new code on your PC."
    static let roomGone = "This PC deleted its pairing. Remove it here, then pair again."
    static let sampleDrafts = "Sample drafts. Pair a PC to review your own."
    static let sampleRules = "Sample rules. Pair a PC to see your own."
    static let sampleNumbers = "Sample numbers. Pair a PC to see your own."
    static let scannerUnavailable = "This device has no camera scanner. Paste the pairing code instead."

    /// "last seen 2 min ago", or "online now" while the PC is online.
    static func lastSeen(online: Bool, at time: Int?, now: Int) -> String {
        if online { return "online now" }
        guard let time else { return "not seen yet" }
        return "last seen " + age(ms: max(0, now - time))
    }

    /// "just now", "2 min ago", "12 hours ago" or "4 days ago".
    static func age(ms: Int) -> String {
        let minutes = ms / 60_000
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = minutes / 60
        if hours < 24 { return hours == 1 ? "1 hour ago" : "\(hours) hours ago" }
        let days = hours / 24
        return days == 1 ? "1 day ago" : "\(days) days ago"
    }

    /// The person-facing sentence for a decision the package refused to build.
    static func reviewError(_ error: ReviewError) -> String {
        switch error {
        case .unknownItem: return "This item is no longer on the list."
        case .desktopOnly: return ItemStatus.desktopOnly.displayText!
        case .decisionPending: return ItemStatus.notSent.displayText!
        case .actionDoesNotFit: return "This action does not fit this item."
        case .importedRule: return "Edit imported rules on your PC."
        case .invalidText: return "Use one line of 1 to 500 characters."
        case .invalidScope: return "Pick a scope from the list."
        }
    }
}

/// Facts for the diagnostics block of the Settings screen (protocol Table 23).
struct Diagnostics: Equatable, Sendable {
    var lastCloseCode: Int?
    var lastError: String?
    var lastDroppedReason: String?
    var framesIgnored = 0

    /// The block of text that the Copy button puts on the pasteboard.
    func text(build: AppInfo, pairingState: String, relayOrigin: String?) -> String {
        [
            "Lastide \(build.version) (build \(build.build))",
            "Pairing: \(pairingState)",
            "Relay: \(relayOrigin ?? "none")",
            "Last close code: \(lastCloseCode.map(String.init) ?? "none")",
            "Last error: \(lastError ?? "none")",
            "Last dropped reason: \(lastDroppedReason ?? "none")",
            "Frames ignored: \(framesIgnored)",
        ].joined(separator: "\n")
    }
}
