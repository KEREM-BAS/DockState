import Foundation

/// Why a saved window will not be (or was not) restored. Shown to the user in plain words.
public enum SkipReason: String, Codable, Sendable, CaseIterable {
    case appNotRunning
    case windowNotFound
    case ambiguous
    case minimized
    case fullscreen
    case displayMissing
    case moveFailed
}

/// What to do with a saved display that is not connected.
public enum MissingDisplayPolicy: String, Codable, Sendable, CaseIterable {
    /// Put the windows on the main display, keeping their relative position.
    case useMainDisplay
    /// Don't touch windows whose display is missing.
    case leaveInPlace
}

public struct PlanItem: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case move(window: LiveWindow, target: Frame, displayID: String)
        case inPlace(window: LiveWindow, displayID: String)
        case skip(SkipReason)
    }

    public var saved: SavedWindow
    public var kind: Kind
    public var id: UUID { saved.id }

    public var liveWindow: LiveWindow? {
        switch kind {
        case .move(let w, _, _), .inPlace(let w, _): w
        case .skip: nil
        }
    }

    public var skipReason: SkipReason? {
        if case .skip(let r) = kind { r } else { nil }
    }
}

/// A complete, side-effect-free description of a restore. The preview, the popover counts,
/// the notification text and the executor all read the same plan.
public struct RestorePlan: Sendable, Equatable {
    public var workspace: Workspace
    public var displayMatch: DisplayMatch
    public var items: [PlanItem]

    public var moves: [PlanItem] { items.filter { if case .move = $0.kind { true } else { false } } }
    public var inPlace: [PlanItem] { items.filter { if case .inPlace = $0.kind { true } else { false } } }
    public var skipped: [PlanItem] { items.filter { $0.skipReason != nil } }
}

public enum RestorePlanner {
    public static func plan(
        workspace: Workspace, currentDisplays: [DisplayDescriptor], liveWindows: [LiveWindow],
        runningBundleIDs: Set<String>, missingDisplayPolicy: MissingDisplayPolicy,
        tolerance: Double = 2
    ) -> RestorePlan {
        let match = DisplayMatcher.match(saved: workspace.displays, current: currentDisplays)
        let mainDisplay = currentDisplays.first(where: \.isMain) ?? currentDisplays.first
        let candidates = workspace.windows.filter { !$0.isExcluded }

        let outcomes = WindowMatcher.match(
            saved: candidates, live: liveWindows, runningBundleIDs: runningBundleIDs,
            expectedDisplays: match.mapping.mapValues(\.frame))

        var claimed = Set<LiveWindowID>()
        let items: [PlanItem] = candidates.map { saved in
            func skip(_ r: SkipReason) -> PlanItem { PlanItem(saved: saved, kind: .skip(r)) }
            let window: LiveWindow
            switch outcomes[saved.id] ?? .notFound {
            case .appNotRunning: return skip(.appNotRunning)
            case .notFound: return skip(.windowNotFound)
            case .ambiguous: return skip(.ambiguous)
            case .matched(let w): window = w
            }
            guard !claimed.contains(window.id) else { return skip(.ambiguous) }
            claimed.insert(window.id)
            if window.isFullscreen { return skip(.fullscreen) }
            if window.isMinimized { return skip(.minimized) }

            guard let savedDisplay = workspace.display(id: saved.displayID) else { return skip(.displayMissing) }
            let target: Frame
            let displayID: String
            if let current = match.mapping[saved.displayID] {
                target = Placement.target(for: saved.frameInDisplay, from: savedDisplay, onto: current)
                displayID = current.id
            } else if missingDisplayPolicy == .useMainDisplay, let main = mainDisplay {
                target = Placement.target(for: saved.frameInDisplay, from: savedDisplay, onto: main, forceProportional: true)
                displayID = main.id
            } else {
                return skip(.displayMissing)
            }
            if window.frame.isApproximatelyEqual(to: target, tolerance: tolerance) {
                return PlanItem(saved: saved, kind: .inPlace(window: window, displayID: displayID))
            }
            return PlanItem(saved: saved, kind: .move(window: window, target: target, displayID: displayID))
        }
        return RestorePlan(workspace: workspace, displayMatch: match, items: items)
    }
}

/// Converts a display-relative saved frame into a global frame on a connected display.
public enum Placement {
    public static func target(
        for frameInDisplay: Frame, from saved: DisplayDescriptor, onto current: DisplayDescriptor,
        forceProportional: Bool = false
    ) -> Frame {
        let sameSize = abs(saved.frame.width - current.frame.width) < 1 && abs(saved.frame.height - current.frame.height) < 1
        var frame: Frame
        if sameSize && !forceProportional {
            frame = frameInDisplay.offsetBy(dx: current.frame.x, dy: current.frame.y)
        } else {
            // Resolution or display changed: keep the position and size proportional
            // to the usable area so the layout keeps its shape.
            let sv = saved.visibleFrame, cv = current.visibleFrame
            let gx = saved.frame.x + frameInDisplay.x, gy = saved.frame.y + frameInDisplay.y
            let rx = (gx - sv.x) / max(sv.width, 1), ry = (gy - sv.y) / max(sv.height, 1)
            let rw = frameInDisplay.width / max(sv.width, 1), rh = frameInDisplay.height / max(sv.height, 1)
            frame = Frame(x: cv.x + rx * cv.width, y: cv.y + ry * cv.height, width: rw * cv.width, height: rh * cv.height)
        }
        frame = frame.clamped(into: current.frame)
        // Keep the title bar below the menu bar so the window stays grabbable.
        if frame.y < current.visibleFrame.y { frame.y = current.visibleFrame.y }
        return frame.clamped(into: current.frame)
    }
}
