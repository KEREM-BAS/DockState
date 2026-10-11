import AppKit
import SwiftUI

/// Opens DockState's windows. A menu bar app has no main window, so windows are created
/// on demand with AppKit and brought to the front explicitly.
@MainActor
final class WindowRouter {
    private var windows: [String: NSWindow] = [:]
    private var closeObservers: [String: NSObjectProtocol] = [:]

    func show<Content: View>(
        _ id: String, title: String, size: NSSize, resizable: Bool = false,
        style: NSWindow.StyleMask = [.titled, .closable], titleVisible: Bool = true,
        onClose: (@MainActor @Sendable () -> Void)? = nil, @ViewBuilder content: () -> Content
    ) {
        if let existing = windows[id] {
            existing.title = title
            bringToFront(existing)
            return
        }
        var mask = style
        if resizable { mask.insert(.resizable); mask.insert(.miniaturizable) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: mask, backing: .buffered, defer: false)
        window.title = title
        window.identifier = NSUserInterfaceItemIdentifier(id)
        window.titleVisibility = titleVisible ? .visible : .hidden
        window.isReleasedWhenClosed = false
        let controller = NSHostingController(rootView: content())
        // Fixed-size windows follow their SwiftUI content's ideal size.
        if !resizable { controller.sizingOptions = [.preferredContentSize] }
        window.contentViewController = controller
        window.setContentSize(resizable ? size : controller.view.fittingSize)
        if resizable { window.contentMinSize = size }
        window.center()
        window.setFrameAutosaveName("DockState.\(id)")
        windows[id] = window
        closeObservers[id] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.forget(id)
                onClose?()
            }
        }
        bringToFront(window)
    }

    func close(_ id: String) {
        windows[id]?.close()
    }

    func isOpen(_ id: String) -> Bool { windows[id] != nil }

    private func forget(_ id: String) {
        if let token = closeObservers.removeValue(forKey: id) { NotificationCenter.default.removeObserver(token) }
        windows[id] = nil
    }

    private func bringToFront(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

enum WindowID {
    static let onboarding = "onboarding"
    static let save = "save"
    static let manage = "manage"
    static let settings = "settings"
    static let preview = "preview"
}

/// Closes the menu bar panel, e.g. after one of its actions opened a window.
@MainActor
func closeMenuBarPopover() {
    StatusItemController.close()
}
