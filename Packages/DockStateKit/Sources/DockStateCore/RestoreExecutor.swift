import Foundation

public enum MoveFailure: Error, Sendable, Equatable {
    case windowGone
    case notMovable
    case timedOut
    case other(String)
}

/// The side-effecting part of restoring, implemented with Accessibility in the app and
/// with fakes in tests.
public protocol WindowMoving: Sendable {
    /// Moves and resizes the window; returns the frame it actually ended up with
    /// (apps may enforce minimum sizes).
    func setFrame(_ frame: Frame, of window: LiveWindowID) async -> Result<Frame, MoveFailure>
    /// The window's frame right now, or nil when it no longer exists.
    func frame(of window: LiveWindowID) async -> Frame?
    /// Called around a series of moves so per-app setup happens once.
    func beginBatch() async
    func endBatch() async
}

public extension WindowMoving {
    func beginBatch() async {}
    func endBatch() async {}
}

public struct UndoEntry: Sendable, Equatable {
    public var window: LiveWindowID
    public var appName: String
    public var before: Frame
    public var after: Frame
    /// Where the restore wanted the window (nil when the move failed part-way).
    public var target: Frame?

    public init(window: LiveWindowID, appName: String, before: Frame, after: Frame, target: Frame? = nil) {
        self.window = window
        self.appName = appName
        self.before = before
        self.after = after
        self.target = target
    }
}

/// Everything needed to put the windows of one restore back.
public struct UndoRecord: Sendable, Equatable {
    public var workspaceID: UUID
    public var workspaceName: String
    public var date: Date
    public var entries: [UndoEntry]

    public init(workspaceID: UUID, workspaceName: String, date: Date, entries: [UndoEntry]) {
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
        self.date = date
        self.entries = entries
    }
}

public struct RestoreResult: Sendable, Equatable {
    public struct Failure: Sendable, Equatable {
        public var saved: SavedWindow
        public var reason: SkipReason

        public init(saved: SavedWindow, reason: SkipReason) {
            self.saved = saved
            self.reason = reason
        }
    }

    public var workspaceID: UUID
    public var workspaceName: String
    public var movedCount: Int
    public var alreadyInPlaceCount: Int
    /// Skipped during planning plus moves that failed.
    public var notRestored: [Failure]
    public var undo: UndoRecord
    public var automatic: Bool

    public init(
        workspaceID: UUID, workspaceName: String, movedCount: Int, alreadyInPlaceCount: Int,
        notRestored: [Failure], undo: UndoRecord, automatic: Bool
    ) {
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
        self.movedCount = movedCount
        self.alreadyInPlaceCount = alreadyInPlaceCount
        self.notRestored = notRestored
        self.undo = undo
        self.automatic = automatic
    }
}

public extension UndoRecord {
    /// Frames this restore achieved, for `RestorePlanner.plan(settled:)`.
    var settledPlacements: [LiveWindowID: SettledPlacement] {
        var result: [LiveWindowID: SettledPlacement] = [:]
        for entry in entries {
            if let target = entry.target { result[entry.window] = SettledPlacement(target: target, actual: entry.after) }
        }
        return result
    }
}

public struct UndoResult: Sendable, Equatable {
    public var restoredCount: Int
    /// The user moved these windows after the restore, so they were left alone.
    public var changedSinceCount: Int
    public var goneCount: Int
}

public enum RestoreExecutor {
    /// Executes the plan's moves one by one. A failing window never stops the others.
    public static func execute(_ plan: RestorePlan, mover: some WindowMoving, automatic: Bool = false, now: Date = Date()) async -> RestoreResult {
        var entries: [UndoEntry] = []
        var failures = plan.skipped.map { RestoreResult.Failure(saved: $0.saved, reason: $0.skipReason!) }
        var moved = 0
        await mover.beginBatch()
        for item in plan.moves {
            guard case .move(let window, let target, _) = item.kind else { continue }
            switch await mover.setFrame(target, of: window.id) {
            case .success(let actual):
                moved += 1
                entries.append(UndoEntry(window: window.id, appName: window.appName, before: window.frame, after: actual, target: target))
            case .failure(let error):
                failures.append(.init(saved: item.saved, reason: error == .windowGone ? .windowNotFound : .moveFailed))
                // A move can fail after the window was already resized or partly moved.
                // Record that, so Undo can still put it back.
                if error != .windowGone, let now = await mover.frame(of: window.id),
                   !now.isApproximatelyEqual(to: window.frame, tolerance: 1) {
                    entries.append(UndoEntry(window: window.id, appName: window.appName, before: window.frame, after: now))
                }
            }
        }
        await mover.endBatch()
        return RestoreResult(
            workspaceID: plan.workspace.id, workspaceName: plan.workspace.name, movedCount: moved,
            alreadyInPlaceCount: plan.inPlace.count, notRestored: failures,
            undo: UndoRecord(workspaceID: plan.workspace.id, workspaceName: plan.workspace.name, date: now, entries: entries),
            automatic: automatic)
    }

    /// Puts windows back where they were before the restore — but only windows that are
    /// still where the restore left them. Anything the user moved since is respected.
    public static func undo(_ record: UndoRecord, mover: some WindowMoving, tolerance: Double = PlacementTolerance.position) async -> UndoResult {
        var restored = 0, changed = 0, gone = 0
        await mover.beginBatch()
        // Newest first, so a window moved twice returns through each step.
        for entry in record.entries.reversed() {
            guard let current = await mover.frame(of: entry.window) else { gone += 1; continue }
            guard current.isApproximatelyEqual(to: entry.after, tolerance: tolerance) else { changed += 1; continue }
            switch await mover.setFrame(entry.before, of: entry.window) {
            case .success: restored += 1
            case .failure(.windowGone): gone += 1
            case .failure: changed += 1
            }
        }
        await mover.endBatch()
        return UndoResult(restoredCount: restored, changedSinceCount: changed, goneCount: gone)
    }
}
