import AppKit
import ApplicationServices
import DockStateCore
import os

private let log = Logger(subsystem: "app.dockstate", category: "windows")

/// A running app as far as window management is concerned.
public struct RunningApp: Sendable, Hashable {
    public var pid: Int32
    public var bundleID: String
    public var name: String

    public init(pid: Int32, bundleID: String, name: String) {
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
    }
}

/// Reads and moves other apps' windows through the Accessibility API.
///
/// Only public API is used. Consequences, by design:
/// - Only windows on the current Space are visible to Accessibility.
/// - Window identity is the AXUIElement itself, valid for the window's lifetime.
public final class AccessibilityWindowSystem: WindowMoving, @unchecked Sendable {
    /// Per-call timeout for reads, so a hung app can't stall a scan.
    private let readTimeout: Float = 0.6
    /// Moves can take longer in busy apps; reporting them as failed too early would
    /// leave a moved window without an undo entry.
    private let writeTimeout: Float = 1.5
    private let lock = NSLock()
    private var elements: [LiveWindowID: AXUIElement] = [:]
    /// Apps whose AXEnhancedUserInterface was turned off for the current batch of moves.
    private var enhancedDisabled: Set<pid_t> = []
    private var inBatch = false

    public init() {}

    /// Regular (Dock-visible) apps except DockState itself. Call on the main actor.
    @MainActor
    public static func runningApps() -> [RunningApp] {
        let me = ProcessInfo.processInfo.processIdentifier
        var skippedNoBundle = 0
        let apps = NSWorkspace.shared.runningApplications.compactMap { app -> RunningApp? in
            guard app.activationPolicy == .regular, app.processIdentifier != me, !app.isTerminated else { return nil }
            guard let bundleID = app.bundleIdentifier else { skippedNoBundle += 1; return nil }
            return RunningApp(pid: app.processIdentifier, bundleID: bundleID, name: app.localizedName ?? bundleID)
        }
        if skippedNoBundle > 0 { log.info("Skipped \(skippedNoBundle, privacy: .public) apps without a bundle identifier") }
        return apps
    }

    /// Lists windows of `apps`. Runs AX calls on the calling thread; call off the main actor.
    ///
    /// `appOrder` counts only windows DockState can save (standard, not minimized), so the
    /// order signal isn't skewed by palettes, dialogs or minimized windows.
    public func windows(of apps: [RunningApp]) -> [LiveWindow] {
        var result: [LiveWindow] = []
        var fresh: [LiveWindowID: AXUIElement] = [:]
        var unreadableApps = 0
        let known = lock.withLock { elements }
        for app in apps {
            let previous = known.filter { $0.key.pid == app.pid }
            let appElement = AXUIElementCreateApplication(app.pid)
            AXUIElementSetMessagingTimeout(appElement, readTimeout)
            guard let windows: [AXUIElement] = appElement.attribute(kAXWindowsAttribute) else { unreadableApps += 1; continue }
            var order = 0
            for window in windows {
                AXUIElementSetMessagingTimeout(window, readTimeout)
                guard let position: CGPoint = window.pointAttribute(kAXPositionAttribute),
                      let size: CGSize = window.sizeAttribute(kAXSizeAttribute) else { continue }
                // Keep a window's identity across scans: some apps (e.g. Terminal) hand out
                // element objects whose hash changes, but CFEqual still recognises them.
                let id: LiveWindowID
                if let existing = previous.first(where: { CFEqual($0.value, window) })?.key {
                    id = existing
                } else {
                    var token = Int(bitPattern: UInt(CFHash(window)))
                    while let other = fresh[LiveWindowID(pid: app.pid, token: token)] ?? previous[LiveWindowID(pid: app.pid, token: token)],
                          !CFEqual(other, window) { token &+= 1 }
                    id = LiveWindowID(pid: app.pid, token: token)
                }
                fresh[id] = window
                let role: String? = window.attribute(kAXRoleAttribute)
                let subrole: String? = window.attribute(kAXSubroleAttribute)
                let minimized: Bool = window.attribute(kAXMinimizedAttribute) ?? false
                var live = LiveWindow(
                    id: id, bundleID: app.bundleID, appName: app.name,
                    title: window.attribute(kAXTitleAttribute), role: role, subrole: subrole,
                    frame: Frame(CGRect(origin: position, size: size)),
                    isMinimized: minimized,
                    isFullscreen: window.attribute("AXFullScreen") ?? false,
                    appOrder: 0)
                if live.isStandard && !minimized {
                    live.appOrder = order
                    order += 1
                } else {
                    live.appOrder = 1000 + order
                }
                result.append(live)
            }
        }
        if unreadableApps > 0 { log.info("\(unreadableApps, privacy: .public) apps didn’t report windows to Accessibility") }
        // Replace what we knew about the scanned apps (closed windows drop out); keep
        // other running apps' elements so undo works across partial rescans.
        let scanned = Set(apps.map(\.pid))
        lock.withLock {
            elements = elements.filter { !scanned.contains($0.key.pid) }.merging(fresh) { _, new in new }
        }
        return result
    }

    /// Forgets windows of apps that are no longer running.
    public func prune(keepingPIDs alive: Set<pid_t>) {
        lock.withLock { elements = elements.filter { alive.contains($0.key.pid) } }
    }

    private func element(for id: LiveWindowID) -> AXUIElement? {
        lock.withLock { elements[id] }
    }

    public func frame(of window: LiveWindowID) async -> Frame? {
        guard let el = element(for: window) else { return nil }
        AXUIElementSetMessagingTimeout(el, readTimeout)
        guard let p = el.pointAttribute(kAXPositionAttribute), let s = el.sizeAttribute(kAXSizeAttribute) else { return nil }
        return Frame(CGRect(origin: p, size: s))
    }

    public func beginBatch() async {
        lock.withLock { inBatch = true }
    }

    public func endBatch() async {
        let pids = lock.withLock {
            let pids = enhancedDisabled
            enhancedDisabled.removeAll()
            inBatch = false
            return pids
        }
        for pid in pids { restoreEnhancedUserInterface(pid) }
    }

    /// Apps with "enhanced user interface" (set by VoiceOver and some utilities) animate AX
    /// moves, which breaks the size/position sequence. Turn it off once per app for the
    /// batch and turn it back on at the end.
    private func disableEnhancedUserInterfaceIfNeeded(_ pid: pid_t) -> Bool {
        let already = lock.withLock { enhancedDisabled.contains(pid) }
        if already { return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, readTimeout)
        guard (app.attribute("AXEnhancedUserInterface") ?? false) == true else { return false }
        app.set("AXEnhancedUserInterface", kCFBooleanFalse)
        lock.withLock { _ = enhancedDisabled.insert(pid) }
        return true
    }

    private func restoreEnhancedUserInterface(_ pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, writeTimeout)
        if app.set("AXEnhancedUserInterface", kCFBooleanTrue) != .success {
            log.error("Couldn’t re-enable enhanced user interface for pid \(pid, privacy: .public)")
        }
    }

    public func setFrame(_ frame: Frame, of window: LiveWindowID) async -> Result<Frame, MoveFailure> {
        guard let el = element(for: window) else { return .failure(.windowGone) }
        AXUIElementSetMessagingTimeout(el, writeTimeout)
        var settable: DarwinBoolean = false
        let check = AXUIElementIsAttributeSettable(el, kAXPositionAttribute as CFString, &settable)
        if check == .invalidUIElement { return .failure(.windowGone) }
        guard check == .success, settable.boolValue else { return .failure(.notMovable) }

        let batched = lock.withLock { inBatch }
        let disabledHere = disableEnhancedUserInterfaceIfNeeded(window.pid)
        defer {
            if disabledHere && !batched {
                restoreEnhancedUserInterface(window.pid)
                lock.withLock { _ = enhancedDisabled.remove(window.pid) }
            }
        }

        // Size → position → size: resizing first avoids the window being pushed back by the
        // edge of a smaller display; the second resize fixes sizes clamped by the old display.
        var errors: [AXError] = []
        errors.append(el.setSize(frame.cgRect.size))
        errors.append(el.setPosition(frame.cgRect.origin))
        errors.append(el.setSize(frame.cgRect.size))

        if errors.contains(.invalidUIElement) { return .failure(.windowGone) }
        if errors.allSatisfy({ $0 == .cannotComplete }) { return .failure(.timedOut) }
        guard let actual = await self.frame(of: window) else { return .failure(.windowGone) }
        if errors.contains(where: { $0 != .success }) {
            log.info("Partial move for pid \(window.pid, privacy: .public): \(errors.map(\.rawValue), privacy: .public)")
        }
        // Position must land (apps may nudge a few points); size may legitimately be
        // constrained by the app.
        let slack = PlacementTolerance.position * 2
        if abs(actual.x - frame.x) > slack || abs(actual.y - frame.y) > slack {
            return .failure(.notMovable)
        }
        return .success(actual)
    }
}

// MARK: - AXUIElement helpers

extension AXUIElement {
    func attribute<T>(_ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    func pointAttribute(_ name: String) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success,
              let v = value, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &point) ? point : nil
    }

    func sizeAttribute(_ name: String) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success,
              let v = value, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(v as! AXValue, .cgSize, &size) ? size : nil
    }

    @discardableResult
    func set(_ name: String, _ value: CFTypeRef) -> AXError {
        AXUIElementSetAttributeValue(self, name as CFString, value)
    }

    func setPosition(_ point: CGPoint) -> AXError {
        var p = point
        guard let v = AXValueCreate(.cgPoint, &p) else { return .failure }
        return set(kAXPositionAttribute, v)
    }

    func setSize(_ size: CGSize) -> AXError {
        var s = size
        guard let v = AXValueCreate(.cgSize, &s) else { return .failure }
        return set(kAXSizeAttribute, v)
    }
}
