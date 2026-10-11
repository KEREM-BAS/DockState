#if DEBUG
import Foundation
import DockStateCore
import DockStateSystem

/// Fictional desk used for README screenshots (`-DockStateDemo YES`), so no real window
/// titles ever end up in the repository. Debug builds only.
enum DemoData {
    static let macbook = DisplayDescriptor(
        id: "demo-mb", uuid: "demo-mb", vendorID: 0x610, modelID: 0xA050, serialNumber: 0, name: "MacBook Pro",
        isBuiltin: true, isMain: false, frame: Frame(x: -1512, y: 458, width: 1512, height: 982),
        visibleFrame: Frame(x: -1512, y: 458, width: 1512, height: 982), pixelWidth: 3024, pixelHeight: 1964, scale: 2)
    static let lg = DisplayDescriptor(
        id: "demo-lg", uuid: "demo-lg", vendorID: 0x1E6D, modelID: 0x5B71, serialNumber: 0x1234, name: "LG UltraFine 27″",
        isBuiltin: false, isMain: true, frame: Frame(x: 0, y: 0, width: 2560, height: 1440),
        visibleFrame: Frame(x: 0, y: 25, width: 2560, height: 1415), pixelWidth: 5120, pixelHeight: 2880, scale: 2)
    static let dell = DisplayDescriptor(
        id: "demo-dell", uuid: "demo-dell", vendorID: 0x10AC, modelID: 0xA0B1, serialNumber: 0, name: "Dell 24″",
        isBuiltin: false, isMain: false, frame: Frame(x: 2560, y: 180, width: 1920, height: 1080),
        visibleFrame: Frame(x: 2560, y: 180, width: 1920, height: 1080), pixelWidth: 1920, pixelHeight: 1080, scale: 1)
    static let displays = [macbook, lg, dell]

    private struct W { var bundle, app, title: String; var display: DisplayDescriptor; var frame: Frame; var order = 0 }

    private static let saved: [W] = [
        W(bundle: "com.apple.dt.Xcode", app: "Xcode", title: "DockState — AppModel.swift", display: lg, frame: Frame(x: 20, y: 45, width: 1560, height: 1375)),
        W(bundle: "com.apple.Terminal", app: "Terminal", title: "~/dev/dockstate", display: lg, frame: Frame(x: 1600, y: 45, width: 940, height: 670)),
        W(bundle: "com.figma.Desktop", app: "Figma", title: "Onboarding", display: lg, frame: Frame(x: 1600, y: 735, width: 940, height: 685)),
        W(bundle: "com.apple.Safari", app: "Safari", title: "Pull requests", display: dell, frame: Frame(x: 20, y: 20, width: 1200, height: 1040), order: 0),
        W(bundle: "com.apple.Safari", app: "Safari", title: "Swift documentation", display: dell, frame: Frame(x: 60, y: 60, width: 1160, height: 1000), order: 1),
        W(bundle: "com.apple.mail", app: "Mail", title: "Inbox", display: dell, frame: Frame(x: 1240, y: 20, width: 660, height: 1040)),
        W(bundle: "com.tinyspeck.slackmacgap", app: "Slack", title: "#dockstate", display: macbook, frame: Frame(x: 20, y: 40, width: 820, height: 920)),
        W(bundle: "com.apple.Notes", app: "Notes", title: "Ideas", display: macbook, frame: Frame(x: 860, y: 40, width: 632, height: 920)),
    ]

    static func workspaces() -> [Workspace] {
        let windows = saved.map {
            SavedWindow(bundleID: $0.bundle, appName: $0.app, title: $0.title, role: "AXWindow", subrole: "AXStandardWindow",
                        displayID: $0.display.id, frameInDisplay: $0.frame, appOrder: $0.order)
        }
        let date = Date(timeIntervalSinceNow: -2 * 86_400)
        return [
            Workspace(name: "Home Desk", displays: displays, windows: windows, createdAt: date, updatedAt: date),
            Workspace(name: "Office", displays: [macbook, Fixture.office], windows: [], createdAt: date, updatedAt: date),
            Workspace(name: "Laptop Only", displays: [macbook], windows: [], createdAt: date, updatedAt: date),
        ]
    }

    private enum Fixture {
        static let office = DisplayDescriptor(
            id: "demo-office", uuid: "demo-office", vendorID: 0x4C2D, modelID: 0x7001, serialNumber: 0x99, name: "Samsung 32″",
            isBuiltin: false, isMain: true, frame: Frame(x: 0, y: 0, width: 2560, height: 1440),
            visibleFrame: Frame(x: 0, y: 25, width: 2560, height: 1415), pixelWidth: 2560, pixelHeight: 1440, scale: 1)
    }

    /// The desk right after reconnecting: macOS left most windows stacked on the laptop; Figma was quit.
    /// With `arranged`, every window sits where it was saved (for the first-save screenshot).
    static func liveWindows(arranged: Bool = false) -> [LiveWindow] {
        var result: [LiveWindow] = []
        // After reconnecting, Figma (not installed here) and Notes were quit.
        for (i, w) in saved.enumerated() where arranged || !quitApps.contains(w.app) {
            var frame = w.frame.offsetBy(dx: w.display.frame.x, dy: w.display.frame.y)
            if !arranged, w.display.id != macbook.id {
                let mb = macbook.frame
                frame = Frame(x: mb.x + 40 + Double(i) * 36, y: mb.y + 40 + Double(i) * 30, width: min(w.frame.width, 1000), height: min(w.frame.height, 700))
            }
            result.append(LiveWindow(id: LiveWindowID(pid: 9000 + Int32(i), token: i), bundleID: w.bundle, appName: w.app,
                                     title: w.title, role: "AXWindow", subrole: "AXStandardWindow", frame: frame, appOrder: w.order))
        }
        return result
    }

    private static let quitApps: Set<String> = ["Figma", "Notes"]

    static func runningApps() -> [RunningApp] {
        Set(saved.filter { !quitApps.contains($0.app) }.map(\.bundle)).sorted().enumerated().map {
            RunningApp(pid: 9000 + Int32($0.offset), bundleID: $0.element, name: $0.element)
        }
    }

    static func lastResult(workspace: Workspace) -> RestoreResult {
        let figma = workspace.windows.first { $0.appName == "Figma" }!
        return RestoreResult(
            workspaceID: workspace.id, workspaceName: workspace.name, movedCount: 5, alreadyInPlaceCount: 2,
            notRestored: [.init(saved: figma, reason: .appNotRunning)],
            undo: UndoRecord(workspaceID: workspace.id, workspaceName: workspace.name, date: Date(), entries: [
                UndoEntry(window: LiveWindowID(pid: 9000, token: 0), appName: "Xcode",
                          before: Frame(x: -1472, y: 498, width: 1000, height: 700), after: Frame(x: 20, y: 45, width: 1560, height: 1375)),
            ]),
            automatic: false)
    }
}
#endif
