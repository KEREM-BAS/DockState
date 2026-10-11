import Foundation
import Testing
@testable import DockStateCore

/// Regression tests for the safety review: wrong windows must never move, finished
/// restores must look finished, and odd-but-legit layouts must be left alone.
@Suite struct ExclusionSafetyTests {
    @Test func excludedWindowIsNeverMovedEvenWhenItsSiblingIsClosed() {
        let s = Scenario.live("com.apple.Safari", "Pull requests", Frame(x: 20, y: 40, width: 1200, height: 900), order: 0, pid: 3)
        let e = Scenario.live("com.apple.Safari", "Music", Frame(x: 1300, y: 40, width: 1200, height: 900), order: 1, pid: 3)
        var ws = WorkspaceCapture.capture(name: "x", displays: [Fixtures.lg], windows: [s, e], includeTitles: true)
        ws.windows[1].isExcluded = true
        // Only the excluded window is open now, somewhere else.
        var eNow = e
        eNow.frame = Frame(x: 600, y: 300, width: 1200, height: 900)
        let plan = RestorePlanner.plan(workspace: ws, currentDisplays: [Fixtures.lg], liveWindows: [eNow],
                                       runningBundleIDs: ["com.apple.Safari"], missingDisplayPolicy: .leaveInPlace)
        #expect(plan.moves.isEmpty)
        #expect(plan.items.count == 1)
    }

    @Test func excludedWindowTitlesOffStillClaimsItsWindow() {
        let s = Scenario.live("com.apple.Terminal", nil, Frame(x: 20, y: 40, width: 800, height: 600), order: 0)
        let e = Scenario.live("com.apple.Terminal", nil, Frame(x: 1300, y: 40, width: 500, height: 300), order: 1)
        var ws = WorkspaceCapture.capture(name: "x", displays: [Fixtures.lg], windows: [s, e], includeTitles: false)
        ws.windows[1].isExcluded = true
        var sNow = s; sNow.frame.origin(100, 100)
        var eNow = e; eNow.frame.origin(900, 500)
        let plan = RestorePlanner.plan(workspace: ws, currentDisplays: [Fixtures.lg], liveWindows: [sNow, eNow],
                                       runningBundleIDs: ["com.apple.Terminal"], missingDisplayPolicy: .leaveInPlace)
        #expect(plan.moves.count == 1)
        #expect(plan.moves.first?.liveWindow?.id == sNow.id)
    }
}

@Suite struct MatcherSafetyTests {
    @Test func unassignedCompetitorMakesTheMatchAmbiguous() {
        // Titles off, two same-size Terminal windows saved; only one is open now.
        let s1 = Scenario.live("com.apple.Terminal", nil, Frame(x: 20, y: 40, width: 800, height: 600), order: 0)
        let s2 = Scenario.live("com.apple.Terminal", nil, Frame(x: 2600, y: 240, width: 800, height: 600), order: 1)
        let ws = WorkspaceCapture.capture(name: "x", displays: Fixtures.homeDisplays, windows: [s1, s2], includeTitles: false)
        var only = s1
        only.frame = Frame(x: -1400, y: 400, width: 800, height: 600)
        let outcomes = WindowMatcher.match(saved: ws.windows, live: [only], runningBundleIDs: ["com.apple.Terminal"], expectedDisplays: [:])
        #expect(ws.windows.allSatisfy { outcomes[$0.id] != .matched(only) })
    }

    @Test func loneWindowWithUnrelatedTitleAndSizeIsNotMoved() {
        let saved = Scenario.live("com.apple.Safari", "GitHub — Pull requests", Frame(x: 20, y: 40, width: 1400, height: 1000), pid: 3)
        let ws = Scenario.save([saved])
        let other = Scenario.live("com.apple.Safari", "YouTube", Frame(x: 300, y: 300, width: 700, height: 500), pid: 3)
        let outcomes = WindowMatcher.match(saved: ws.windows, live: [other], runningBundleIDs: ["com.apple.Safari"], expectedDisplays: [:])
        #expect(outcomes[ws.windows[0].id] == .notFound)
    }

    @Test func loneWindowWithUnrelatedTitleButSameSizeStillMatches() {
        // Terminal titles change with the running command; size keeps it recognisable.
        let saved = Scenario.live("com.apple.Terminal", "~/dev/dockstate", Frame(x: 20, y: 40, width: 900, height: 600))
        let ws = Scenario.save([saved])
        var now = saved
        now.title = "vim — notes"
        now.frame.origin(-1400, 400)
        let outcomes = WindowMatcher.match(saved: ws.windows, live: [now], runningBundleIDs: ["com.apple.Terminal"], expectedDisplays: [:])
        #expect(outcomes[ws.windows[0].id] == .matched(now))
    }
}

@Suite struct InPlaceToleranceTests {
    @Test func constrainedSizeCountsAsInPlaceAfterRestore() async {
        let original = Scenario.homeDeskWindows()
        let ws = Scenario.save(original)
        let now = Scenario.cascadeOntoLaptop(original)
        let server = FakeWindowServer(now)
        // Terminal snaps to a character grid: it ends up 30pt shorter than asked.
        await server.setMinimum(now[1].id, 0, 0)
        let plan = RestorePlanner.plan(workspace: ws, currentDisplays: Fixtures.homeDisplays, liveWindows: now,
                                       runningBundleIDs: Scenario.running(now), missingDisplayPolicy: .leaveInPlace)
        let result = await RestoreExecutor.execute(plan, mover: GridSnappingMover(base: server, snapID: now[1].id))
        var after = now
        for i in after.indices { after[i].frame = await server.frame(of: after[i].id)! }
        let replan = RestorePlanner.plan(workspace: ws, currentDisplays: Fixtures.homeDisplays, liveWindows: after,
                                         runningBundleIDs: Scenario.running(after), missingDisplayPolicy: .leaveInPlace,
                                         settled: result.undo.settledPlacements)
        #expect(replan.moves.isEmpty)
    }

    @Test func smallSizeDifferencesCountAsInPlace() {
        let target = Frame(x: 100, y: 100, width: 900, height: 600)
        #expect(Frame(x: 102, y: 99, width: 893, height: 612).isPlacementEquivalent(to: target))
        #expect(!Frame(x: 110, y: 100, width: 900, height: 600).isPlacementEquivalent(to: target))
        #expect(!Frame(x: 100, y: 100, width: 700, height: 600).isPlacementEquivalent(to: target))
    }
}

/// Wraps the fake server and makes one window snap its height down to a 30pt grid.
struct GridSnappingMover: WindowMoving {
    let base: FakeWindowServer
    let snapID: LiveWindowID

    func setFrame(_ frame: Frame, of window: LiveWindowID) async -> Result<Frame, MoveFailure> {
        var f = frame
        if window == snapID { f.height = (frame.height / 30).rounded(.down) * 30 - 30 }
        return await base.setFrame(f, of: window)
    }

    func frame(of window: LiveWindowID) async -> Frame? { await base.frame(of: window) }
}

@Suite struct PlacementSafetyTests {
    @Test func windowStraddlingDisplaysIsNotMovedRightAfterSaving() {
        // Midpoint on the Dell, left part (incl. part of the title bar) over the LG.
        let w = Scenario.live("com.apple.Notes", "Ideas", Frame(x: 2400, y: 300, width: 400, height: 300))
        let ws = Scenario.save([w])
        let plan = RestorePlanner.plan(workspace: ws, currentDisplays: Fixtures.homeDisplays, liveWindows: [w],
                                       runningBundleIDs: ["com.apple.Notes"], missingDisplayPolicy: .leaveInPlace)
        #expect(plan.moves.isEmpty)
        #expect(plan.inPlace.count == 1)
    }

    @Test func windowHangingOffTheBottomIsLeftAlone() {
        let w = Scenario.live("com.apple.Notes", "Ideas", Frame(x: 200, y: 1100, width: 600, height: 700))
        let ws = Scenario.save([w])
        let plan = RestorePlanner.plan(workspace: ws, currentDisplays: Fixtures.homeDisplays, liveWindows: [w],
                                       runningBundleIDs: ["com.apple.Notes"], missingDisplayPolicy: .leaveInPlace)
        #expect(plan.moves.isEmpty)
    }

    @Test func unreachableTitleBarIsPulledBelowTheMenuBar() {
        var lg = Fixtures.lg
        // Display got shorter (resolution change); the window would end up above the screen.
        let saved = Frame(x: 100, y: -200, width: 1200, height: 2000)
        lg.visibleFrame = Frame(x: 0, y: 25, width: 2560, height: 1415)
        let target = Placement.target(for: saved, from: Fixtures.lg, onto: lg, allDisplays: [lg])
        #expect(target.y >= lg.visibleFrame.y)
        #expect(target.maxY <= lg.visibleFrame.maxY + 0.001)
        #expect(target.height <= lg.visibleFrame.height)
    }
}

@Suite struct ExecutorSafetyTests {
    @Test func failedMoveThatChangedTheWindowIsUndoable() async {
        let original = Scenario.homeDeskWindows()
        let ws = Scenario.save(original)
        let now = Scenario.cascadeOntoLaptop(original)
        let plan = RestorePlanner.plan(workspace: ws, currentDisplays: Fixtures.homeDisplays, liveWindows: now,
                                       runningBundleIDs: Scenario.running(now), missingDisplayPolicy: .leaveInPlace)
        let server = FakeWindowServer(now)
        let mover = HalfMover(base: server, failing: now[0].id)
        let result = await RestoreExecutor.execute(plan, mover: mover)
        #expect(result.notRestored.contains { $0.reason == .moveFailed })
        #expect(result.undo.entries.contains { $0.window == now[0].id })
        _ = await RestoreExecutor.undo(result.undo, mover: server)
        #expect(await server.frame(of: now[0].id) == now[0].frame)
    }

    @Test func windowMovedTwiceIsUndoneStepByStep() async {
        let w = Scenario.live("com.apple.Notes", "Ideas", Frame(x: 0, y: 30, width: 500, height: 400))
        let server = FakeWindowServer([w])
        let a = Frame(x: 100, y: 100, width: 500, height: 400), b = Frame(x: 300, y: 300, width: 500, height: 400)
        _ = await server.setFrame(a, of: w.id)
        _ = await server.setFrame(b, of: w.id)
        let record = UndoRecord(workspaceID: UUID(), workspaceName: "x", date: Date(), entries: [
            UndoEntry(window: w.id, appName: "Notes", before: w.frame, after: a),
            UndoEntry(window: w.id, appName: "Notes", before: a, after: b),
        ])
        let undo = await RestoreExecutor.undo(record, mover: server)
        #expect(undo.restoredCount == 2)
        #expect(await server.frame(of: w.id) == w.frame)
    }
}

/// Resizes the window but then reports failure, like an app that refuses the position.
struct HalfMover: WindowMoving {
    let base: FakeWindowServer
    let failing: LiveWindowID

    func setFrame(_ frame: Frame, of window: LiveWindowID) async -> Result<Frame, MoveFailure> {
        if window == failing {
            if var current = await base.frame(of: window) {
                current.width = frame.width
                current.height = frame.height
                _ = await base.setFrame(current, of: window)
            }
            return .failure(.notMovable)
        }
        return await base.setFrame(frame, of: window)
    }

    func frame(of window: LiveWindowID) async -> Frame? { await base.frame(of: window) }
}

@Suite struct RecognitionRuleTests {
    @Test func extraDisplayStillRecognizesTheDesk() {
        let sidecar = Fixtures.display("SIDECAR", vendor: 0, model: 0, name: "Sidecar Display (AirPlay)", x: -1024, y: 1440, w: 1024, h: 768)
        let m = DisplayMatcher.match(saved: Fixtures.homeDisplays, current: Fixtures.homeDisplays + [sidecar])
        #expect(m.quality == .withExtraDisplays)
        #expect(m.quality.isRecognized)
    }

    @Test func laptopOnlyWorkspaceNeverMatchesADesk() {
        let m = DisplayMatcher.match(saved: [Fixtures.macbook], current: [Fixtures.macbook, Fixtures.lg])
        #expect(m.quality == .partial)
    }

    @Test func lidOpenedOnClamshellDeskIsRecognized() {
        let clamshell = [Fixtures.lg, Fixtures.dell]
        let m = DisplayMatcher.match(saved: clamshell, current: Fixtures.homeDisplays)
        #expect(m.quality == .withExtraDisplays)
    }

    @Test func unidentifiedDisplaysNeedTheSameName() {
        let a = Fixtures.display("A", vendor: 0, model: 0, name: "AirPlay TV", x: 0)
        let b = Fixtures.display("B", vendor: 0, model: 0, name: "DisplayLink", x: 0)
        #expect(DisplayMatcher.pairScore(saved: a, current: b) == nil)
        #expect(DisplayMatcher.pairScore(saved: a, current: a) != nil)
    }

    @Test func alwaysWorkspaceWinsOverRecentlyEditedOne() {
        let coding = Workspace(name: "Coding", displays: Fixtures.homeDisplays, windows: [], autoMode: .always,
                               createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
        let meeting = Workspace(name: "Meeting", displays: Fixtures.homeDisplays, windows: [], autoMode: .never,
                                createdAt: Date(timeIntervalSince1970: 10), updatedAt: Date())
        #expect(WorkspaceRecognizer.recognized([meeting, coding], current: Fixtures.homeDisplays)?.workspace.name == "Coding")
    }

    @Test func mostRecentlyRestoredWinsAmongEquals() {
        let a = Workspace(name: "A", displays: Fixtures.homeDisplays, windows: [], createdAt: Date(timeIntervalSince1970: 100),
                          lastRestoredAt: Date(timeIntervalSince1970: 50))
        let b = Workspace(name: "B", displays: Fixtures.homeDisplays, windows: [], createdAt: Date(timeIntervalSince1970: 0),
                          lastRestoredAt: Date(timeIntervalSince1970: 500))
        #expect(WorkspaceRecognizer.recognized([a, b], current: Fixtures.homeDisplays)?.workspace.name == "B")
    }

    @Test func positionsAreComparedRelativeToTheArrangement() {
        // Same two identical monitors, but the whole arrangement shifted because the
        // main display changed: assignment must follow the arrangement.
        let left = Fixtures.display("A", x: 0, y: 0)
        let right = Fixtures.display("B", x: 1920, y: 0)
        var newLeft = left; newLeft.id = "P1"; newLeft.uuid = "P1"; newLeft.frame.origin(-1920, 0)
        var newRight = right; newRight.id = "P2"; newRight.uuid = "P2"; newRight.frame.origin(0, 0)
        let m = DisplayMatcher.match(saved: [left, right], current: [newRight, newLeft])
        #expect(m.mapping["A"]?.id == "P1")
        #expect(m.mapping["B"]?.id == "P2")
        #expect(!m.isAmbiguous)
    }
}
