// A throw-away app with a single window, used by DockState's end-to-end self-test so the
// test never has to move, quit or relaunch the developer's own apps.
//
// Every launch opens the window at a slightly different position, like an app whose
// window macOS rearranged — which is what "place apps opened later" has to fix.
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let defaults = UserDefaults.standard
        let launches = defaults.integer(forKey: "launches")
        defaults.set(launches + 1, forKey: "launches")
        // Three positions in turn, so the next two launches never open where this one did.
        let shift = CGFloat(launches % 3) * 70
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(x: screen.minX + 200 + shift, y: screen.minY + 200 + shift, width: 520, height: 340)
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "DockStateTestWindow"
        window.isRestorable = false
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
