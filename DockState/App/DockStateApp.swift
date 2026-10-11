import SwiftUI
import DockStateCore

@main
struct DockStateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // The menu bar icon and its panel are AppKit (see StatusItemController). This scene
        // only provides the app menu commands, which appear while a DockState window is open.
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(String(localized: "About DockState")) { delegate.actions.showSettings(tab: .about) }
            }
            CommandGroup(replacing: .appSettings) {
                Button(String(localized: "Settings…")) { delegate.actions.showSettings() }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
