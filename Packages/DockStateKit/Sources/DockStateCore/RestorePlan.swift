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

    /// Apps with saved windows that aren't running, in plan order, each once.
    public var missingApps: [String] {
        var seen = Set<String>()
        return items.compactMap { item in
            guard item.skipReason == .appNotRunning, seen.insert(item.saved.bundleID).inserted else { return nil }
            return item.saved.bundleID
        }
    }
}

/// Where a restore actually left a window, so a window that can't take the exact target
/// size (minimum sizes, character grids) still counts as "in place" afterwards.
public struct SettledPlacement: Sendable, Equatable {
    public var target: Frame
    public var actual: Frame

    public init(target: Frame, actual: Frame) {
        self.target = target
        self.actual = actual
    }
}

public enum RestorePlanner {
    /// - Parameter settled: frames the last restore achieved per live window (see `SettledPlacement`).
    public static func plan(
        workspace: Workspace, currentDisplays: [DisplayDescriptor], liveWindows: [LiveWindow],
        runningBundleIDs: Set<String>, missingDisplayPolicy: MissingDisplayPolicy,
        settled: [LiveWindowID: SettledPlacement] = [:]
    ) -> RestorePlan {
        let match = DisplayMatcher.match(saved: workspace.displays, current: currentDisplays)
        let mainDisplay = currentDisplays.first(where: \.isMain) ?? currentDisplays.first

        // Excluded windows take part in matching so they keep their own live window —
        // otherwise that window could be mistaken for another saved window and moved.
        let outcomes = WindowMatcher.match(
            saved: workspace.windows, live: liveWindows, runningBundleIDs: runningBundleIDs,
            expectedDisplays: match.mapping.mapValues(\.frame))

        var claimed = Set<LiveWindowID>()
        for saved in workspace.windows where saved.isExcluded {
            if case .matched(let w) = outcomes[saved.id] { claimed.insert(w.id) }
        }

        let items: [PlanItem] = workspace.windows.filter { !$0.isExcluded }.map { saved in
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
                target = Placement.target(for: saved.frameInDisplay, from: savedDisplay, onto: current, allDisplays: currentDisplays)
                displayID = current.id
            } else if missingDisplayPolicy == .useMainDisplay, let main = mainDisplay {
                target = Placement.target(for: saved.frameInDisplay, from: savedDisplay, onto: main,
                                          allDisplays: currentDisplays, forceProportional: true)
                displayID = main.id
            } else {
                return skip(.displayMissing)
            }
            if window.frame.isPlacementEquivalent(to: target) || isSettled(window, target: target, settled: settled) {
                return PlanItem(saved: saved, kind: .inPlace(window: window, displayID: displayID))
            }
            return PlanItem(saved: saved, kind: .move(window: window, target: target, displayID: displayID))
        }
        return RestorePlan(workspace: workspace, displayMatch: match, items: items)
    }

    /// The last restore already sent this window to `target` and it hasn't moved since.
    private static func isSettled(_ window: LiveWindow, target: Frame, settled: [LiveWindowID: SettledPlacement]) -> Bool {
        guard let s = settled[window.id] else { return false }
        return s.target.isApproximatelyEqual(to: target, tolerance: 1)
            && window.frame.isApproximatelyEqual(to: s.actual, tolerance: 2)
    }
}

/// Converts a display-relative saved frame into a global frame on a connected display.
public enum Placement {
    /// Height of the strip at the top of a window that must stay reachable (title bar).
    static let titleBarHeight: Double = 30
    /// Minimum width of that strip that must be on some display.
    static let minimumGrabWidth: Double = 80

    /// - Parameters:
    ///   - allDisplays: every connected display; a window may legitimately straddle displays or
    ///     hang off an edge, so it is only pulled in when its title bar would be unreachable.
    ///   - forceProportional: map relative to the usable area even if sizes match (used when
    ///     placing windows from a missing display onto another one).
    public static func target(
        for frameInDisplay: Frame, from saved: DisplayDescriptor, onto current: DisplayDescriptor,
        allDisplays: [DisplayDescriptor] = [], forceProportional: Bool = false
    ) -> Frame {
        let sameSize = abs(saved.frame.width - current.frame.width) < 1 && abs(saved.frame.height - current.frame.height) < 1
        let frame: Frame
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
        let areas = (allDisplays.isEmpty ? [current] : allDisplays).map(\.visibleFrame)
        if isReachable(frame, on: areas) { return frame }
        // Pull the window fully into the usable area of its display: size first, so the
        // title bar can never end up under the menu bar.
        return frame.clamped(into: current.visibleFrame)
    }

    /// Whether enough of the title bar is on a usable display area to grab the window.
    static func isReachable(_ frame: Frame, on areas: [Frame]) -> Bool {
        let strip = Frame(x: frame.x, y: frame.y, width: frame.width, height: titleBarHeight)
        let needed = min(minimumGrabWidth, frame.width)
        return areas.contains { area in
            let hit = strip.intersection(area)
            return hit.width >= needed && hit.height >= titleBarHeight * 0.66
        }
    }
}
