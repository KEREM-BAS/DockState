import Foundation
import DockStateCore

/// User-facing wording for core values. Kept in one place so translations stay consistent.
enum Copy {
    static func reason(_ reason: SkipReason, appName: String) -> String {
        switch reason {
        case .appNotRunning: String(localized: "\(appName) isn’t open")
        case .windowNotFound: String(localized: "This window was closed")
        case .ambiguous: String(localized: "Couldn’t tell which \(appName) window this is")
        case .minimized: String(localized: "Window is minimized")
        case .fullscreen: String(localized: "Window is in full screen")
        case .displayMissing: String(localized: "Its display isn’t connected")
        case .moveFailed: String(localized: "\(appName) didn’t allow the move")
        }
    }

    static func displayCount(_ workspace: Workspace) -> String {
        if workspace.displays.count == 1, workspace.displays[0].isBuiltin {
            return String(localized: "Built-in display")
        }
        return String(localized: "\(workspace.displays.count) displays")
    }

    static func connection(_ match: DisplayMatch) -> String {
        switch match.quality {
        case .exact, .sameDisplays, .withExtraDisplays: String(localized: "connected")
        case .partial: String(localized: "partly connected")
        case .none: String(localized: "not connected")
        }
    }

    static func autoMode(_ mode: AutoMode) -> String {
        switch mode {
        case .ask: String(localized: "Ask me")
        case .always: String(localized: "Always restore")
        case .never: String(localized: "Do nothing")
        }
    }

    static func autoModeHelp(_ mode: AutoMode) -> String {
        switch mode {
        case .ask: String(localized: "DockState shows a notification and waits for you.")
        case .always: String(localized: "Windows are restored right away. You can still undo.")
        case .never: String(localized: "DockState stays quiet. Restore from the menu bar.")
        }
    }

    static func windowCount(_ n: Int) -> String { String(localized: "\(n) windows") }

    static func displayList(_ displays: [DisplayDescriptor]) -> String {
        ListFormatter.localizedString(byJoining: displays.map(\.name))
    }
}
