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
    /// Per-call timeout so a hung app can't stall a scan or a restore.
    private let messagingTimeout: Float = 0.6
    private let lock = NSLock()
    private var elements: [LiveWindowID: AXUIElement] = [:]

    public init() {}

    /// Regular (Dock-visible) apps except DockState itself. Call on the main actor.
    @MainActor
    public static func runningApps() -> [RunningApp] {
        let me = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, app.processIdentifier != me, !app.isTerminated,
                  let bundleID = app.bundleIdentifier else { return nil }
            return RunningApp(pid: app.processIdentifier, bundleID: bundleID, name: app.localizedName ?? bundleID)
        }
    }

    /// Lists windows of `apps`. Runs AX calls on the calling thread; call off the main actor.
    public func windows(of apps: [RunningApp]) -> [LiveWindow] {
        var result: [LiveWindow] = []
        var fresh: [LiveWindowID: AXUIElement] = [:]
        for app in apps {
            let appElement = AXUIElementCreateApplication(app.pid)
            AXUIElementSetMessagingTimeout(appElement, messagingTimeout)
            guard let windows: [AXUIElement] = appElement.attribute(kAXWindowsAttribute) else { continue }
            for (order, window) in windows.enumerated() {
                AXUIElementSetMessagingTimeout(window, messagingTimeout)
                guard let position: CGPoint = window.pointAttribute(kAXPositionAttribute),
                      let size: CGSize = window.sizeAttribute(kAXSizeAttribute) else { continue }
                let id = LiveWindowID(pid: app.pid, token: Int(bitPattern: UInt(CFHash(window))))
                fresh[id] = window
                result.append(LiveWindow(
                    id: id, bundleID: app.bundleID, appName: app.name,
                    title: window.attribute(kAXTitleAttribute),
                    role: window.attribute(kAXRoleAttribute),
                    subrole: window.attribute(kAXSubroleAttribute),
                    frame: Frame(CGRect(origin: position, size: size)),
                    isMinimized: window.attribute(kAXMinimizedAttribute) ?? false,
                    isFullscreen: window.attribute("AXFullScreen") ?? false,
                    appOrder: order))
            }
        }
        lock.lock()
        // Keep elements of still-running apps so undo works across rescans.
        let alive = Set(apps.map(\.pid))
        elements = elements.filter { alive.contains($0.key.pid) }.merging(fresh) { _, new in new }
        lock.unlock()
        return result
    }

    private func element(for id: LiveWindowID) -> AXUIElement? {
        lock.lock(); defer { lock.unlock() }
        return elements[id]
    }

    public func frame(of window: LiveWindowID) async -> Frame? {
        guard let el = element(for: window),
              let p = el.pointAttribute(kAXPositionAttribute), let s = el.sizeAttribute(kAXSizeAttribute) else { return nil }
        return Frame(CGRect(origin: p, size: s))
    }

    public func setFrame(_ frame: Frame, of window: LiveWindowID) async -> Result<Frame, MoveFailure> {
        guard let el = element(for: window) else { return .failure(.windowGone) }
        var settable: DarwinBoolean = false
        let check = AXUIElementIsAttributeSettable(el, kAXPositionAttribute as CFString, &settable)
        if check == .invalidUIElement { return .failure(.windowGone) }
        guard check == .success, settable.boolValue else { return .failure(.notMovable) }

        // Apps with "enhanced user interface" animate AX moves, which breaks the
        // size/position sequence. Turn it off for the move and restore it afterwards.
        let app = AXUIElementCreateApplication(window.pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        let enhanced: Bool = app.attribute("AXEnhancedUserInterface") ?? false
        if enhanced { app.set("AXEnhancedUserInterface", kCFBooleanFalse) }
        defer { if enhanced { app.set("AXEnhancedUserInterface", kCFBooleanTrue) } }

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
        // Position must land; size may legitimately be constrained by the app.
        if abs(actual.x - frame.x) > 8 || abs(actual.y - frame.y) > 8 {
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
