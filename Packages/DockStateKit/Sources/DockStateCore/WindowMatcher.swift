import Foundation

/// Pairs saved windows with live windows.
///
/// Guiding rule: moving the wrong window is worse than not moving a window. Every pair
/// must clear a minimum score, and a pair is rejected as ambiguous when swapping it with
/// another plausible pair would score almost as well.
public enum WindowMatcher {
    public struct Config: Sendable {
        public var minimumScore: Double = 20
        public var ambiguityMargin: Double = 8
        public init() {}
    }

    public enum Outcome: Equatable, Sendable {
        case matched(LiveWindow)
        case ambiguous
        case notFound
        case appNotRunning
    }

    /// Score for "this live window is that saved window", or nil when impossible.
    /// `expectedDisplay` is the connected display the saved window belongs on, if any.
    static func score(saved: SavedWindow, live: LiveWindow, expectedDisplay: Frame?, uniqueInApp: Bool) -> Double? {
        guard saved.bundleID == live.bundleID, live.isStandard else { return nil }
        var score = 0.0
        if let a = saved.title?.trimmingCharacters(in: .whitespaces), !a.isEmpty,
           let b = live.title?.trimmingCharacters(in: .whitespaces), !b.isEmpty {
            score += a == b ? 60 : 35 * titleSimilarity(a, b)
        }
        let sw = saved.frameInDisplay.width, sh = saved.frameInDisplay.height
        let dw = abs(sw - live.frame.width) / max(sw, live.frame.width, 1)
        let dh = abs(sh - live.frame.height) / max(sh, live.frame.height, 1)
        score += 20 * max(0, 1 - (dw + dh) * 2.5)
        if let display = expectedDisplay, display.contains(x: live.frame.midX, y: live.frame.midY) { score += 10 }
        switch abs(saved.appOrder - live.appOrder) {
        case 0: score += 6
        case 1: score += 3
        default: break
        }
        if uniqueInApp { score += 40 }
        return score
    }

    /// Word-level Jaccard similarity; titles like "Inbox — 3 unread" vs "Inbox — 5 unread" stay close.
    static func titleSimilarity(_ a: String, _ b: String) -> Double {
        func tokens(_ s: String) -> Set<String> {
            Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        }
        let ta = tokens(a), tb = tokens(b)
        guard !ta.isEmpty || !tb.isEmpty else { return 0 }
        return Double(ta.intersection(tb).count) / Double(ta.union(tb).count)
    }

    /// Matches every saved window. `expectedDisplays` maps saved display id → connected frame.
    public static func match(
        saved: [SavedWindow], live: [LiveWindow], runningBundleIDs: Set<String>,
        expectedDisplays: [String: Frame], config: Config = Config()
    ) -> [UUID: Outcome] {
        var outcomes: [UUID: Outcome] = [:]
        let savedByApp = Dictionary(grouping: saved, by: \.bundleID)
        let liveByApp = Dictionary(grouping: live.filter(\.isStandard), by: \.bundleID)

        for (bundleID, savedGroup) in savedByApp {
            guard runningBundleIDs.contains(bundleID) else {
                savedGroup.forEach { outcomes[$0.id] = .appNotRunning }
                continue
            }
            let liveGroup = liveByApp[bundleID] ?? []
            guard !liveGroup.isEmpty else {
                savedGroup.forEach { outcomes[$0.id] = .notFound }
                continue
            }
            let unique = savedGroup.count == 1 && liveGroup.count == 1
            let scores: [[Double?]] = savedGroup.map { s in
                liveGroup.map { l in
                    score(saved: s, live: l, expectedDisplay: expectedDisplays[s.displayID], uniqueInApp: unique)
                        .flatMap { $0 >= config.minimumScore ? $0 : nil }
                }
            }
            let assignment = Assignment.solve(scores)
            let usedColumns = Set(assignment.compactMap { $0 })

            for (i, s) in savedGroup.enumerated() {
                guard let j = assignment[i], let sij = scores[i][j] else {
                    outcomes[s.id] = .notFound
                    continue
                }
                var ambiguous = false
                // Would swapping with another matched pair be nearly as good?
                for (k, other) in assignment.enumerated() where k != i {
                    guard let l = other, let skl = scores[k][l], let sil = scores[i][l], let skj = scores[k][j] else { continue }
                    if (sij + skl) - (sil + skj) < config.ambiguityMargin { ambiguous = true; break }
                }
                // Would an unclaimed live window fit just as well?
                if !ambiguous {
                    for jj in liveGroup.indices where !usedColumns.contains(jj) {
                        if let alt = scores[i][jj], sij - alt < config.ambiguityMargin { ambiguous = true; break }
                    }
                }
                outcomes[s.id] = ambiguous ? .ambiguous : .matched(liveGroup[j])
            }
        }
        return outcomes
    }
}
