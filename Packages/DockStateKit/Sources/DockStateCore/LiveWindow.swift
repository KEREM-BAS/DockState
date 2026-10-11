import Foundation

/// Opaque identity of a window that exists right now. Only valid while the window lives.
public struct LiveWindowID: Hashable, Sendable, CustomStringConvertible {
    public var pid: Int32
    /// Distinguishes windows of the same process for the lifetime of a scan.
    public var token: Int

    public init(pid: Int32, token: Int) {
        self.pid = pid
        self.token = token
    }

    public var description: String { "\(pid):\(token)" }
}

/// A window as seen through the Accessibility API at one moment.
public struct LiveWindow: Hashable, Sendable, Identifiable {
    public var id: LiveWindowID
    public var bundleID: String
    public var appName: String
    public var title: String?
    public var role: String?
    public var subrole: String?
    /// Global frame (top-left origin).
    public var frame: Frame
    public var isMinimized: Bool
    public var isFullscreen: Bool
    /// Front-to-back position among this app's windows (0 = frontmost).
    public var appOrder: Int

    public init(
        id: LiveWindowID, bundleID: String, appName: String, title: String?, role: String?, subrole: String?,
        frame: Frame, isMinimized: Bool = false, isFullscreen: Bool = false, appOrder: Int
    ) {
        self.id = id
        self.bundleID = bundleID
        self.appName = appName
        self.title = title
        self.role = role
        self.subrole = subrole
        self.frame = frame
        self.isMinimized = isMinimized
        self.isFullscreen = isFullscreen
        self.appOrder = appOrder
    }

    /// Regular document/app windows. Dialogs, sheets, palettes and panels are left alone.
    public var isStandard: Bool {
        (role == nil || role == "AXWindow") && (subrole == nil || subrole == "AXStandardWindow")
    }
}

/// Builds a workspace from the current windows. Only standard, visible windows on the
/// current Space are captured.
public enum WorkspaceCapture {
    public static func capture(
        name: String, displays: [DisplayDescriptor], windows: [LiveWindow], includeTitles: Bool,
        excluding excludedIDs: Set<LiveWindowID> = []
    ) -> Workspace {
        let saved: [SavedWindow] = windows.compactMap { w in
            guard w.isStandard, !w.isMinimized, !w.isFullscreen, !excludedIDs.contains(w.id),
                  let display = displays.display(containing: w.frame) else { return nil }
            return SavedWindow(
                bundleID: w.bundleID, appName: w.appName, title: includeTitles ? w.title : nil,
                role: w.role, subrole: w.subrole, displayID: display.id,
                frameInDisplay: w.frame.offsetBy(dx: -display.frame.x, dy: -display.frame.y),
                appOrder: w.appOrder)
        }
        return Workspace(name: name, displays: displays, windows: saved)
    }

    /// Windows that would be captured (for the save sheet / onboarding list).
    public static func capturable(_ windows: [LiveWindow], displays: [DisplayDescriptor]) -> [LiveWindow] {
        windows.filter { $0.isStandard && !$0.isMinimized && !$0.isFullscreen && displays.display(containing: $0.frame) != nil }
    }
}
