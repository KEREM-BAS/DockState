import Foundation

/// How well the connected displays correspond to a saved workspace's displays.
public enum SetupMatchQuality: Int, Comparable, Sendable {
    /// No saved display is connected.
    case none
    /// Some saved displays are connected, or extra displays are attached.
    case partial
    /// Exactly the saved displays are connected, but arrangement or resolution changed.
    case sameDisplays
    /// Same displays, same arrangement, same resolution.
    case exact

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// Whether the setup counts as "the same desk" for suggestions and automation.
    public var isRecognized: Bool { self >= .sameDisplays }
}

public struct DisplayMatch: Sendable, Equatable {
    /// Saved display id → the connected display it corresponds to.
    public var mapping: [String: DisplayDescriptor]
    /// Saved display ids that are not connected.
    public var missing: [String]
    /// Connected display ids that are not part of the saved setup.
    public var extra: [String]
    public var quality: SetupMatchQuality
    /// True when two different assignments explain the displays equally well
    /// (e.g. two identical monitors without serial numbers in identical positions).
    public var isAmbiguous: Bool
    public var score: Double

    public static let empty = DisplayMatch(mapping: [:], missing: [], extra: [], quality: .none, isAmbiguous: false, score: 0)
}

/// Decides which connected display is which saved display.
public enum DisplayMatcher {
    /// Score for "saved and current are the same physical display", or nil when impossible.
    public static func pairScore(saved: DisplayDescriptor, current: DisplayDescriptor) -> Double? {
        guard saved.isBuiltin == current.isBuiltin else { return nil }
        var score = 0.0
        if saved.isBuiltin {
            score += 100
        } else {
            let sameModel = saved.vendorID == current.vendorID && saved.modelID == current.modelID
            let virtual = saved.vendorID == 0 && current.vendorID == 0
            if !sameModel && !(virtual && saved.name == current.name) { return nil }
            score += sameModel ? 40 : 30
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
        let dx = saved.frame.x - current.frame.x, dy = saved.frame.y - current.frame.y
        let distance = (dx * dx + dy * dy).squareRoot()
        score += 20 * max(0, 1 - distance / 3000)
        return score
    }

    public static func match(saved: [DisplayDescriptor], current: [DisplayDescriptor]) -> DisplayMatch {
        guard !saved.isEmpty, !current.isEmpty else {
            return DisplayMatch(mapping: [:], missing: saved.map(\.id), extra: current.map(\.id),
                                quality: .none, isAmbiguous: false, score: 0)
        }
        let scores: [[Double?]] = saved.map { s in current.map { c in pairScore(saved: s, current: c) } }

        // Exhaustive search; setups have a handful of displays so this stays tiny.
        // Objective: maximise matched count first, then total score.
        var best: (count: Int, score: Double, assignment: [Int?])?
        var bestTies = 0
        var used = Array(repeating: false, count: current.count)
        var assignment = Array<Int?>(repeating: nil, count: saved.count)

        func search(_ i: Int, _ count: Int, _ score: Double) {
            if i == saved.count {
                if let b = best {
                    if count > b.count || (count == b.count && score > b.score + 1e-9) {
                        best = (count, score, assignment); bestTies = 0
                    } else if count == b.count && abs(score - b.score) <= 1e-9 && assignment != b.assignment {
                        bestTies += 1
                    }
                } else {
                    best = (count, score, assignment)
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
        } else if missing.isEmpty && extra.isEmpty {
            quality = sameGeometry ? .exact : .sameDisplays
        } else {
            quality = .partial
        }
        return DisplayMatch(mapping: mapping, missing: missing, extra: extra, quality: quality,
                            isAmbiguous: bestTies > 0, score: result.score)
    }
}

/// Picks the saved workspace that belongs to the connected displays, if any.
public enum WorkspaceRecognizer {
    public struct Candidate: Sendable {
        public var workspace: Workspace
        public var match: DisplayMatch
    }

    /// All workspaces with their display match, best first.
    public static func rank(_ workspaces: [Workspace], current: [DisplayDescriptor]) -> [Candidate] {
        workspaces
            .map { Candidate(workspace: $0, match: DisplayMatcher.match(saved: $0.displays, current: current)) }
            .sorted {
                if $0.match.quality != $1.match.quality { return $0.match.quality > $1.match.quality }
                if $0.match.score != $1.match.score { return $0.match.score > $1.match.score }
                return $0.workspace.updatedAt > $1.workspace.updatedAt
            }
    }

    /// The workspace to suggest: recognised setups only, never partial or ambiguous ones.
    public static func recognized(_ workspaces: [Workspace], current: [DisplayDescriptor]) -> Candidate? {
        rank(workspaces, current: current).first { $0.match.quality.isRecognized && !$0.match.isAmbiguous }
    }
}
