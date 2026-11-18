import LastideKit
import SwiftUI

/// The screens a screenshot run can open, named by the launch argument `-LastideScreen`.
enum ScreenshotScreen: String, CaseIterable, Sendable {
    case queue, draftDetail, library, ruleDetail, learning, settings, pairingDisclosure, pairingCode
}

/// A screenshot run: `-LastideScreen <screen> -LastideColorScheme light|dark`. The run uses demo data only, and never
/// reads the disk, the Keychain or the network.
struct ScreenshotLaunch: Sendable {
    let screen: ScreenshotScreen
    let dark: Bool

    static func fromArguments() -> ScreenshotLaunch? {
        let defaults = UserDefaults.standard
        guard let name = defaults.string(forKey: "LastideScreen") else { return nil }
        guard let screen = ScreenshotScreen(rawValue: name) else { preconditionFailure("unknown -LastideScreen \(name)") }
        switch defaults.string(forKey: "LastideColorScheme") {
        case "light": return ScreenshotLaunch(screen: screen, dark: false)
        case "dark": return ScreenshotLaunch(screen: screen, dark: true)
        default: preconditionFailure("a screenshot run needs -LastideColorScheme light or dark")
        }
    }
}

@main
struct LastideApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: AppModel
    private let screenshot: ScreenshotLaunch?
    private let background = BackgroundFlush()

    init() {
        let facts = DeviceFacts.current()
        let screenshot = ScreenshotLaunch.fromArguments()
        self.screenshot = screenshot
        do {
            if let screenshot {
                let model = try AppModel(demoWith: facts, sockets: URLSessionSocketFactory())
                switch screenshot.screen {
                case .pairingDisclosure: model.showPairingStep(.disclosure)
                // The check code of the Lastide test vector (protocol section 10.3).
                case .pairingCode: model.showPairingStep(.checkCode("714 390"))
                default: break
                }
                _model = State(initialValue: model)
            } else {
                _model = State(initialValue: try AppModel(facts: facts, storage: FileStorage.appSupport(),
                                                          secrets: KeychainStore(), sockets: URLSessionSocketFactory(),
                                                          now: currentTimeMs))
            }
        } catch {
            fatalError("Lastide could not start: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model, screenshot: screenshot?.screen)
                .preferredColorScheme(screenshot.map { $0.dark ? .dark : .light })
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            guard screenshot == nil else { return }
            switch phase {
            case .active:
                model.cameToScreen()
            case .background:
                let model = model
                background.run { await model.leftScreen() }
            default:
                break
            }
        }
    }
}
