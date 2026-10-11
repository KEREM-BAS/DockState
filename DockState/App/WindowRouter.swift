import AppKit
import SwiftUI

/// Opens DockState's windows. A menu bar app has no main window, so windows are created
/// on demand with AppKit and brought to the front explicitly.
///
/// While any DockState window is open, DockState is a regular app — it shows in the Dock
/// and in Cmd+Tab so its windows are easy to get back to. When the last one closes it goes
/// back to being a menu bar app.
///
/// Windows the router didn't open (Sparkle's update windows, alerts, open and save panels)
/// count too, and float like DockState's own (see `adoptOtherWindows`).
@MainActor
final class WindowRouter {
    private var windows: [String: NSWindow] = [:]
    private var closeObservers: [String: NSObjectProtocol] = [:]
    private var reactivationObserver: NSObjectProtocol?
    private var otherWindowObserver: NSObjectProtocol?
    /// Open router windows across all routers (the activation policy is app-wide).
    private static var openWindowCount = 0
    private static var routerWindows: Set<ObjectIdentifier> = []
    private static var policyTask: Task<Void, Never>?
    private static var otherWindowsTask: Task<Void, Never>?
    /// The app the user was in before DockState's first window opened; it gets focus back
    /// when the last DockState window closes.
    private static weak var previousApp: NSRunningApplication?

    /// Whether any DockState window is open (all routers).
    static var hasOpenWindows: Bool { openWindowCount > 0 }
    /// Whether windows should float above other apps (Settings › General).
    private let keepOnTop: @MainActor () -> Bool
    /// Never floated: onboarding must not cover System Settings while the user grants
    /// the Accessibility permission there.
    private static let neverOnTop: Set<String> = [WindowID.onboarding]

    init(keepOnTop: @escaping @MainActor () -> Bool = { false }) {
        self.keepOnTop = keepOnTop
    }

    private func level(for id: String) -> NSWindow.Level {
        floats && !Self.neverOnTop.contains(id) ? .floating : .normal
    }

    /// While onboarding is open nothing floats, so neither it nor System Settings (where
    /// the permission is granted) ends up underneath another DockState window.
    private var floats: Bool {
        keepOnTop() && windows[WindowID.onboarding] == nil
    }

    /// Treats the app's other titled windows like router windows. Call once at launch.
    func adoptOtherWindows() {
        guard otherWindowObserver == nil else { return }
        otherWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard let self, let window, Self.isOtherWindow(window) else { return }
                // Without this, Settings (kept on top) would cover Sparkle's update window.
                if self.floats, window.level == .normal { window.level = .floating }
                Self.otherWindowAppeared()
            }
        }
    }

    /// A titled window the router didn't open. DockState's own panels are borderless, and
    /// sheets move with their window.
    private static func isOtherWindow(_ window: NSWindow) -> Bool {
        window.styleMask.contains(.titled) && window.sheetParent == nil
            && !routerWindows.contains(ObjectIdentifier(window))
    }

    private static var otherWindowsVisible: Bool {
        NSApp.windows.contains { $0.isVisible && isOtherWindow($0) }
    }

    /// Lets an external app (the browser for a link) come in front of DockState's windows
    /// until DockState is used again.
    func lowerUntilReactivated() {
        guard keepOnTop() else { return }
        for window in windows.values { window.level = .normal }
        for window in NSApp.windows where Self.isOtherWindow(window) && window.level == .floating { window.level = .normal }
        guard reactivationObserver == nil else { return }
        reactivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let observer = self.reactivationObserver { NotificationCenter.default.removeObserver(observer) }
                self.reactivationObserver = nil
                self.applyLevels()
            }
        }
    }

    /// Re-applies the on-top setting to open windows (when the setting changes).
    func applyLevels() {
        for (id, window) in windows { window.level = level(for: id) }
        for window in NSApp.windows where window.isVisible && Self.isOtherWindow(window)
            && (window.level == .normal || window.level == .floating) {
            window.level = floats ? .floating : .normal
        }
    }

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
        Self.windowOpened()
        var mask = style
        if resizable { mask.insert(.resizable); mask.insert(.miniaturizable) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: mask, backing: .buffered, defer: false)
        window.title = title
        window.identifier = NSUserInterfaceItemIdentifier(id)
        window.level = level(for: id)
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
        window.tabbingMode = .disallowed
        windows[id] = window
        Self.routerWindows.insert(ObjectIdentifier(window))
        applyLevels()
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
        if let window = windows.removeValue(forKey: id) {
            Self.routerWindows.remove(ObjectIdentifier(window))
            applyLevels()
            Self.windowClosed()
        }
    }

    private static func windowOpened() {
        if openWindowCount == 0 {
            let front = NSWorkspace.shared.frontmostApplication
            if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = front }
        }
        openWindowCount += 1
        policyTask?.cancel()
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
    }

    private static func windowClosed() {
        openWindowCount = max(0, openWindowCount - 1)
        guard openWindowCount == 0 else { return }
        becomeMenuBarAppWhenIdle()
    }

    private static func otherWindowAppeared() {
        // DockState is already frontmost here; don't hand focus to an app from long ago.
        if openWindowCount == 0, otherWindowsTask == nil { previousApp = nil }
        policyTask?.cancel()
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        // Alerts are ordered out rather than closed, so poll until none is visible.
        guard otherWindowsTask == nil else { return }
        otherWindowsTask = Task {
            while otherWindowsVisible {
                try? await Task.sleep(for: .seconds(1))
            }
            otherWindowsTask = nil
            if openWindowCount == 0 { becomeMenuBarAppWhenIdle() }
        }
    }

    private static func becomeMenuBarAppWhenIdle() {
        // A moment later, so closing one window and opening another doesn't flicker the Dock.
        policyTask?.cancel()
        policyTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            // An alert (e.g. after onboarding) or an update window still needs DockState
            // to be a regular app.
            while NSApp.modalWindow != nil || otherWindowsVisible {
                try? await Task.sleep(for: .milliseconds(400))
                if Task.isCancelled { return }
            }
            guard !Task.isCancelled, openWindowCount == 0 else { return }
            NSApp.setActivationPolicy(.accessory)
            // Hand focus back instead of leaving an invisible app active.
            if NSApp.isActive {
                if let previousApp, !previousApp.isTerminated { previousApp.activate() } else { NSApp.deactivate() }
            }
        }
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
