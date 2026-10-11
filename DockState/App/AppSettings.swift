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
    /// Keep Manage, Settings, Preview and Save above other apps' windows.
    var keepWindowsOnTop: Bool { didSet { defaults.set(keepWindowsOnTop, forKey: Keys.onTop) } }
    /// Place windows of apps opened after a restore (see AppModel.placeLateApp).
    var placeLateApps: Bool { didSet { defaults.set(placeLateApps, forKey: Keys.placeLate) } }
    var didPromptForAccessibility: Bool { didSet { defaults.set(didPromptForAccessibility, forKey: Keys.prompted) } }
    /// This app was trusted at some point; missing permission later suggests a stale entry.
    var permissionWasGranted: Bool { didSet { defaults.set(permissionWasGranted, forKey: Keys.wasGranted) } }
    /// Global shortcuts take over the same keys in every other app, so they are off until
    /// the user turns them on.
    var globalShortcutsEnabled: Bool { didSet { defaults.set(globalShortcutsEnabled, forKey: Keys.shortcuts) } }
    /// Chosen key combinations; an action without an entry has no shortcut.
    var shortcuts: [ShortcutAction: KeyCombo] {
        didSet { defaults.set(try? JSONEncoder().encode(shortcuts), forKey: Keys.shortcutCombos) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [Keys.notify: true, Keys.titles: true, Keys.shortcuts: false, Keys.placeLate: true, Keys.onTop: true])
        hasCompletedOnboarding = defaults.bool(forKey: Keys.onboarding)
        notifyOnConnect = defaults.bool(forKey: Keys.notify)
        useWindowTitles = defaults.bool(forKey: Keys.titles)
        missingDisplayPolicy = defaults.string(forKey: Keys.missing).flatMap(MissingDisplayPolicy.init) ?? .useMainDisplay
        // Choosing to restore a workspace means wanting its apps: open them by default.
        appNotRunningPolicy = defaults.string(forKey: Keys.notRunning).flatMap(AppNotRunningPolicy.init) ?? .openFirst
        didPromptForAccessibility = defaults.bool(forKey: Keys.prompted)
        permissionWasGranted = defaults.bool(forKey: Keys.wasGranted)
        placeLateApps = defaults.bool(forKey: Keys.placeLate)
        keepWindowsOnTop = defaults.bool(forKey: Keys.onTop)
        globalShortcutsEnabled = defaults.bool(forKey: Keys.shortcuts)
        if let data = defaults.data(forKey: Keys.shortcutCombos),
           let saved = try? JSONDecoder().decode([ShortcutAction: KeyCombo].self, from: data) {
            shortcuts = saved
        } else {
            shortcuts = Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { ($0, $0.defaultCombo) })
        }
    }

    private enum Keys {
        static let onboarding = "hasCompletedOnboarding"
        static let notify = "notifyOnConnect"
        static let titles = "useWindowTitles"
        static let missing = "missingDisplayPolicy"
        static let notRunning = "appNotRunningPolicy"
        static let prompted = "didPromptForAccessibility"
        static let wasGranted = "permissionWasGranted"
        static let placeLate = "placeLateApps"
        static let onTop = "keepWindowsOnTop"
        static let shortcuts = "globalShortcutsEnabled"
        static let shortcutCombos = "shortcutCombos"
    }
}
