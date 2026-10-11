import Foundation
import Observation
import DockStateCore

/// What to do when a workspace expects an app that isn't running.
enum AppNotRunningPolicy: String, CaseIterable {
    case skip
    case openFirst
}

/// User preferences, persisted in UserDefaults. Only a handful of decisions; everything
/// else uses a sensible default.
@MainActor
@Observable
final class AppSettings {
    private let defaults: UserDefaults

    var hasCompletedOnboarding: Bool { didSet { defaults.set(hasCompletedOnboarding, forKey: Keys.onboarding) } }
    var notifyOnConnect: Bool { didSet { defaults.set(notifyOnConnect, forKey: Keys.notify) } }
    /// Window titles improve matching for apps with several windows. They stay on this Mac.
    var useWindowTitles: Bool { didSet { defaults.set(useWindowTitles, forKey: Keys.titles) } }
    var missingDisplayPolicy: MissingDisplayPolicy { didSet { defaults.set(missingDisplayPolicy.rawValue, forKey: Keys.missing) } }
    var appNotRunningPolicy: AppNotRunningPolicy { didSet { defaults.set(appNotRunningPolicy.rawValue, forKey: Keys.notRunning) } }
    var didPromptForAccessibility: Bool { didSet { defaults.set(didPromptForAccessibility, forKey: Keys.prompted) } }
    var globalShortcutsEnabled: Bool { didSet { defaults.set(globalShortcutsEnabled, forKey: Keys.shortcuts) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [Keys.notify: true, Keys.titles: true, Keys.shortcuts: true])
        hasCompletedOnboarding = defaults.bool(forKey: Keys.onboarding)
        notifyOnConnect = defaults.bool(forKey: Keys.notify)
        useWindowTitles = defaults.bool(forKey: Keys.titles)
        missingDisplayPolicy = defaults.string(forKey: Keys.missing).flatMap(MissingDisplayPolicy.init) ?? .useMainDisplay
        appNotRunningPolicy = defaults.string(forKey: Keys.notRunning).flatMap(AppNotRunningPolicy.init) ?? .skip
        didPromptForAccessibility = defaults.bool(forKey: Keys.prompted)
        globalShortcutsEnabled = defaults.bool(forKey: Keys.shortcuts)
    }

    private enum Keys {
        static let onboarding = "hasCompletedOnboarding"
        static let notify = "notifyOnConnect"
        static let titles = "useWindowTitles"
        static let missing = "missingDisplayPolicy"
        static let notRunning = "appNotRunningPolicy"
        static let prompted = "didPromptForAccessibility"
        static let shortcuts = "globalShortcutsEnabled"
    }
}
