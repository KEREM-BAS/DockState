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
/// count too; while one is open, DockState's own windows don't float (see
/// `adoptOtherWindows`).
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
    /// Windows the router didn't open that became key; released ones drop out.
    private static var otherWindows: [WeakWindow] = []
    /// One of them is on screen (not minimized): DockState's windows don't float meanwhile.
    private static var otherWindowsShown = false
    /// When the last router window closed; an update window right after it (Sparkle's
    /// question after onboarding) still hands focus back to the app the user was in.
    private static var lastWindowClosed: Date?
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
    /// the permission is granted) ends up underneath another DockState window. While an
    /// update window or alert is on screen nothing floats either: it stays in front, and
    /// links it opens (release notes, Version History) come in front of DockState. After a
    /// link opened, nothing floats until DockState is used again.
    private var floats: Bool {
        keepOnTop() && windows[WindowID.onboarding] == nil && !Self.otherWindowsShown && reactivationObserver == nil
    }

    /// Treats the app's other titled windows like router windows: DockState stays in the
    /// Dock and Cmd+Tab while they're open. Call once at launch.
    func adoptOtherWindows() {
        guard otherWindowObserver == nil else { return }
        otherWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard let self, let window, Self.isOtherWindow(window) else { return }
                self.otherWindowAppeared(window)
            }
        }
    }

    /// Brings an open update window or alert forward (a click on the Dock icon). False if
    /// there is none.
    static func bringOtherWindowsForward() -> Bool {
        guard let window = otherWindows.compactMap(\.window).last(where: { $0.isVisible || $0.isMiniaturized }) else {
            return false
        }
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return true
    }

    /// A titled window the router didn't open. DockState's own panels are borderless, and
    /// sheets move with their window.
    private static func isOtherWindow(_ window: NSWindow) -> Bool {
        window.styleMask.contains(.titled) && window.sheetParent == nil
            && !routerWindows.contains(ObjectIdentifier(window))
    }

    private static var otherWindowsVisible: Bool {
        otherWindows.contains { $0.window.map { $0.isVisible && !$0.isMiniaturized } ?? false }
    }

    /// Minimized windows, and all of them while DockState is hidden (⌘H), still count.
    private static var otherWindowsOpen: Bool {
        otherWindows.removeAll { $0.window == nil }
        if NSApp.isHidden { return !otherWindows.isEmpty }
        return otherWindows.contains { $0.window.map { $0.isVisible || $0.isMiniaturized } ?? false }
    }

    /// Lets an external app (the browser for a link) come in front of DockState's windows
    /// until DockState is used again.
    func lowerUntilReactivated() {
        guard keepOnTop() else { return }
        for window in windows.values { window.level = .normal }
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
        lastWindowClosed = Date()
        becomeMenuBarAppWhenIdle()
    }

    private func otherWindowAppeared(_ window: NSWindow) {
        if !Self.otherWindows.contains(where: { $0.window === window }) { Self.otherWindows.append(WeakWindow(window: window)) }
        // DockState is already frontmost here; don't hand focus to an app from long ago.
        let justClosed = Self.lastWindowClosed.map { Date().timeIntervalSince($0) < 3 } ?? false
        if Self.openWindowCount == 0, Self.otherWindowsTask == nil, !justClosed { Self.previousApp = nil }
        Self.policyTask?.cancel()
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        if !Self.otherWindowsShown {
            Self.otherWindowsShown = true
            applyLevels()
            window.orderFront(nil)
        }
        // Alerts are ordered out rather than closed, so poll until none is open.
        guard Self.otherWindowsTask == nil else { return }
        Self.otherWindowsTask = Task { [weak self] in
            while Self.otherWindowsOpen {
                try? await Task.sleep(for: .seconds(1))
                // Minimizing it lets DockState's windows float again (and restoring stops it).
                let shown = Self.otherWindowsVisible
                if shown != Self.otherWindowsShown {
                    Self.otherWindowsShown = shown
                    self?.applyLevels()
                }
            }
            Self.otherWindowsTask = nil
            Self.otherWindowsShown = false
            self?.applyLevels()
            if Self.openWindowCount == 0 { Self.becomeMenuBarAppWhenIdle() }
        }
    }

    private static func becomeMenuBarAppWhenIdle() {
        // A moment later, so closing one window and opening another doesn't flicker the Dock.
        policyTask?.cancel()
        policyTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            // An alert (e.g. after onboarding) or an update window still needs DockState
            // to be a regular app.
            while NSApp.modalWindow != nil || otherWindowsOpen {
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

private struct WeakWindow {
    weak var window: NSWindow?
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
