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
}

public struct UndoEntry: Sendable, Equatable {
    public var window: LiveWindowID
    public var appName: String
    public var before: Frame
    public var after: Frame
}

/// Everything needed to put the windows of one restore back.
public struct UndoRecord: Sendable, Equatable {
    public var workspaceID: UUID
    public var workspaceName: String
    public var date: Date
    public var entries: [UndoEntry]
}

public struct RestoreResult: Sendable, Equatable {
    public struct Failure: Sendable, Equatable {
        public var saved: SavedWindow
        public var reason: SkipReason
    }

    public var workspaceID: UUID
    public var workspaceName: String
    public var movedCount: Int
    public var alreadyInPlaceCount: Int
    /// Skipped during planning plus moves that failed.
    public var notRestored: [Failure]
    public var undo: UndoRecord
    public var automatic: Bool
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
        for item in plan.moves {
            guard case .move(let window, let target, _) = item.kind else { continue }
            switch await mover.setFrame(target, of: window.id) {
            case .success(let actual):
                moved += 1
                entries.append(UndoEntry(window: window.id, appName: window.appName, before: window.frame, after: actual))
            case .failure(let error):
                failures.append(.init(saved: item.saved, reason: error == .windowGone ? .windowNotFound : .moveFailed))
            }
        }
        return RestoreResult(
            workspaceID: plan.workspace.id, workspaceName: plan.workspace.name, movedCount: moved,
            alreadyInPlaceCount: plan.inPlace.count, notRestored: failures,
            undo: UndoRecord(workspaceID: plan.workspace.id, workspaceName: plan.workspace.name, date: now, entries: entries),
            automatic: automatic)
    }

    /// Puts windows back where they were before the restore — but only windows that are
    /// still where the restore left them. Anything the user moved since is respected.
    public static func undo(_ record: UndoRecord, mover: some WindowMoving, tolerance: Double = 4) async -> UndoResult {
        var restored = 0, changed = 0, gone = 0
        for entry in record.entries {
            guard let current = await mover.frame(of: entry.window) else { gone += 1; continue }
            guard current.isApproximatelyEqual(to: entry.after, tolerance: tolerance) else { changed += 1; continue }
            switch await mover.setFrame(entry.before, of: entry.window) {
            case .success: restored += 1
            case .failure(.windowGone): gone += 1
            case .failure: changed += 1
            }
        }
        return UndoResult(restoredCount: restored, changedSinceCount: changed, goneCount: gone)
    }
}
