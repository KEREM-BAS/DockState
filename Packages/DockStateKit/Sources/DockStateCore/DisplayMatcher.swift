import Foundation

/// How well the connected displays correspond to a saved workspace's displays.
public enum SetupMatchQuality: Int, Comparable, Sendable {
    /// No saved display is connected.
    case none
    /// Some saved displays are missing.
    case partial
    /// Every saved display is connected, plus extra ones (Sidecar, a projector, the
    /// laptop lid opened). Only for workspaces that include an external display — a
    /// laptop-only workspace never "matches" a desk.
    case withExtraDisplays
    /// Exactly the saved displays are connected, but arrangement or resolution changed.
    case sameDisplays
    /// Same displays, same arrangement, same resolution.
    case exact

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// Whether the setup counts as "the same desk" for suggestions and automation.
    public var isRecognized: Bool { self >= .withExtraDisplays }
}

public struct DisplayMatch: Sendable, Equatable {
    /// Saved display id → the connected display it corresponds to.
    public var mapping: [String: DisplayDescriptor]
    /// Saved display ids that are not connected.
    public var missing: [String]
    /// Connected display ids that are not part of the saved setup.
    public var extra: [String]
    public var quality: SetupMatchQuality
    /// True when a different assignment explains the displays (almost) equally well
    /// (e.g. two identical monitors without serial numbers in the same positions).
    public var isAmbiguous: Bool
    public var score: Double

    public static let empty = DisplayMatch(mapping: [:], missing: [], extra: [], quality: .none, isAmbiguous: false, score: 0)
}

/// Decides which connected display is which saved display.
public enum DisplayMatcher {
    /// Two assignments whose totals differ by less than this are indistinguishable.
    static let ambiguityMargin = 1.0

    /// Score for "saved and current are the same physical display", or nil when impossible.
    ///
    /// `savedOrigin` / `currentOrigin` are the top-left corners of each setup's bounding box,
    /// so positions are compared relative to the arrangement rather than to whichever
    /// display happens to be the main one.
    public static func pairScore(
        saved: DisplayDescriptor, current: DisplayDescriptor,
        savedOrigin: (x: Double, y: Double) = (0, 0), currentOrigin: (x: Double, y: Double) = (0, 0)
    ) -> Double? {
        guard saved.isBuiltin == current.isBuiltin else { return nil }
        var score = 0.0
        if saved.isBuiltin {
            score += 100
        } else {
            let unidentified = saved.vendorID == 0 && saved.modelID == 0 && current.vendorID == 0 && current.modelID == 0
            if unidentified {
                // Virtual displays (AirPlay, DisplayLink, some adapters) report no EDID ids;
                // only the name can tell them apart.
                guard saved.name == current.name else { return nil }
                score += 30
            } else {
                guard saved.vendorID == current.vendorID && saved.modelID == current.modelID else { return nil }
                score += 40
            }
            if saved.serialNumber != 0 && current.serialNumber != 0 {
                // EDID serials are unique per unit when present.
                guard saved.serialNumber == current.serialNumber else { return nil }
                score += 100
            }
        }
        if let a = saved.uuid, let b = current.uuid, a == b { score += 60 }
        if saved.name == current.name { score += 5 }
        if saved.pixelWidth == current.pixelWidth && saved.pixelHeight == current.pixelHeight { score += 5 }
        if saved.scale == current.scale { score += 2 }
        // Arrangement is the only way to tell identical monitors apart.
        let dx = (saved.frame.x - savedOrigin.x) - (current.frame.x - currentOrigin.x)
        let dy = (saved.frame.y - savedOrigin.y) - (current.frame.y - currentOrigin.y)
        let distance = (dx * dx + dy * dy).squareRoot()
        score += 20 * max(0, 1 - distance / 3000)
        return score
    }

    static func origin(of displays: [DisplayDescriptor]) -> (x: Double, y: Double) {
        (displays.map(\.frame.x).min() ?? 0, displays.map(\.frame.y).min() ?? 0)
    }

    public static func match(saved: [DisplayDescriptor], current: [DisplayDescriptor]) -> DisplayMatch {
        guard !saved.isEmpty, !current.isEmpty else {
            return DisplayMatch(mapping: [:], missing: saved.map(\.id), extra: current.map(\.id),
                                quality: .none, isAmbiguous: false, score: 0)
        }
        // Compare positions relative to the displays that could be the same on both sides.
        // Extra displays (an opened lid, Sidecar) must not shift the reference point, or
        // identical monitors could be swapped.
        let pairable = saved.map { s in current.map { c in pairScore(saved: s, current: c) != nil } }
        let savedPairable = saved.indices.filter { i in pairable[i].contains(true) }.map { saved[$0] }
        let currentPairable = current.indices.filter { j in saved.indices.contains { pairable[$0][j] } }.map { current[$0] }
        let so = origin(of: savedPairable.isEmpty ? saved : savedPairable)
        let co = origin(of: currentPairable.isEmpty ? current : currentPairable)
        let scores: [[Double?]] = saved.map { s in
            current.map { c in pairScore(saved: s, current: c, savedOrigin: so, currentOrigin: co) }
        }

        // Exhaustive search over assignments; setups have a handful of displays.
        // Objective: maximise matched count first, then total score. The runner-up with the
        // same count tells us whether the answer is ambiguous.
        typealias Candidate = (count: Int, score: Double, assignment: [Int?])
        var best: Candidate?
        var runnerUp: Candidate?
        var used = Array(repeating: false, count: current.count)
        var assignment = Array<Int?>(repeating: nil, count: saved.count)

        func better(_ a: Candidate, than b: Candidate?) -> Bool {
            guard let b else { return true }
            return a.count > b.count || (a.count == b.count && a.score > b.score)
        }

        func search(_ i: Int, _ count: Int, _ score: Double) {
            if i == saved.count {
                let candidate: Candidate = (count, score, assignment)
                if better(candidate, than: best) {
                    runnerUp = best
                    best = candidate
                } else if better(candidate, than: runnerUp) {
                    runnerUp = candidate
                }
                return
            }
            for j in current.indices where !used[j] {
                guard let s = scores[i][j] else { continue }
                used[j] = true; assignment[i] = j
                search(i + 1, count + 1, score + s)
                used[j] = false; assignment[i] = nil
            }
            search(i + 1, count, score)
        }
        search(0, 0, 0)

        guard let result = best else { return .empty }
        let ambiguous = runnerUp.map { $0.count == result.count && result.count > 0 && result.score - $0.score < ambiguityMargin } ?? false

        var mapping: [String: DisplayDescriptor] = [:]
        var missing: [String] = []
        var matchedCurrent = Set<Int>()
        var sameGeometry = true
        for (i, s) in saved.enumerated() {
            if let j = result.assignment[i] {
                mapping[s.id] = current[j]
                matchedCurrent.insert(j)
                let c = current[j]
                if !s.frame.isApproximatelyEqual(to: c.frame, tolerance: 1)
                    || s.pixelWidth != c.pixelWidth || s.pixelHeight != c.pixelHeight {
                    sameGeometry = false
                }
            } else {
                missing.append(s.id)
            }
        }
        let extra = current.indices.filter { !matchedCurrent.contains($0) }.map { current[$0].id }

        let quality: SetupMatchQuality
        if mapping.isEmpty {
            quality = .none
        } else if !missing.isEmpty {
            quality = .partial
        } else if !extra.isEmpty {
            quality = saved.contains { !$0.isBuiltin } ? .withExtraDisplays : .partial
        } else {
            quality = sameGeometry ? .exact : .sameDisplays
        }
        return DisplayMatch(mapping: mapping, missing: missing, extra: extra, quality: quality,
                            isAmbiguous: ambiguous, score: result.score)
    }
}

/// Picks the saved workspace that belongs to the connected displays, if any.
public enum WorkspaceRecognizer {
    public struct Candidate: Sendable {
        public var workspace: Workspace
        public var match: DisplayMatch
    }

    /// All workspaces with their display match, best first.
    ///
    /// Better quality wins, then the workspace covering more of the connected displays.
    /// Several workspaces can be saved for the same desk. Among those the order is: a workspace set to "Always restore", then the one restored most recently,
    /// then the newest. Renaming or editing a workspace never changes which one wins.
    public static func rank(_ workspaces: [Workspace], current: [DisplayDescriptor]) -> [Candidate] {
        workspaces
            .map { Candidate(workspace: $0, match: DisplayMatcher.match(saved: $0.displays, current: current)) }
            .sorted { a, b in
                if a.match.quality != b.match.quality { return a.match.quality > b.match.quality }
                // A workspace describing more of the connected displays beats a subset of them.
                if a.match.mapping.count != b.match.mapping.count { return a.match.mapping.count > b.match.mapping.count }
                if a.match.extra.count != b.match.extra.count { return a.match.extra.count < b.match.extra.count }
                let aAlways = a.workspace.autoMode == .always, bAlways = b.workspace.autoMode == .always
                if aAlways != bAlways { return aAlways }
                let ar = a.workspace.lastRestoredAt ?? .distantPast, br = b.workspace.lastRestoredAt ?? .distantPast
                if ar != br { return ar > br }
                if a.workspace.createdAt != b.workspace.createdAt { return a.workspace.createdAt > b.workspace.createdAt }
                return a.match.score > b.match.score
            }
    }

    /// The workspace to suggest: recognised setups only, never partial or ambiguous ones.
    public static func recognized(_ workspaces: [Workspace], current: [DisplayDescriptor]) -> Candidate? {
        rank(workspaces, current: current).first { $0.match.quality.isRecognized && !$0.match.isAmbiguous }
    }
}
