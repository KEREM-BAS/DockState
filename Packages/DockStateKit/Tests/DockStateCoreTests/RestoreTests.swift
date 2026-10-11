import Foundation
import Testing
@testable import DockStateCore

/// In-memory window server used to exercise restore and undo without Accessibility.
actor FakeWindowServer: WindowMoving {
    var frames: [LiveWindowID: Frame]
    var failing: Set<LiveWindowID> = []
    /// Simulates apps that enforce a minimum size.
    var minimumSize: [LiveWindowID: (Double, Double)] = [:]
    private(set) var moveCount = 0

    init(_ windows: [LiveWindow]) {
        frames = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0.frame) })
    }

    func setFrame(_ frame: Frame, of window: LiveWindowID) async -> Result<Frame, MoveFailure> {
        guard frames[window] != nil else { return .failure(.windowGone) }
        if failing.contains(window) { return .failure(.notMovable) }
        moveCount += 1
        var f = frame
        if let (mw, mh) = minimumSize[window] { f.width = max(f.width, mw); f.height = max(f.height, mh) }
        frames[window] = f
        return .success(f)
    }

    func frame(of window: LiveWindowID) async -> Frame? { frames[window] }

    func userMoves(_ id: LiveWindowID, to frame: Frame) { frames[id] = frame }
    func close(_ id: LiveWindowID) { frames[id] = nil }
    func fail(_ id: LiveWindowID) { failing.insert(id) }
    func setMinimum(_ id: LiveWindowID, _ w: Double, _ h: Double) { minimumSize[id] = (w, h) }
}

enum Scenario {
    static func live(_ bundle: String, _ title: String?, _ frame: Frame, order: Int = 0, pid: Int32 = 1,
                     minimized: Bool = false, fullscreen: Bool = false, subrole: String = "AXStandardWindow") -> LiveWindow {
        return LiveWindow(id: LiveWindowID(pid: pid, token: Int.random(in: 1...Int.max)), bundleID: bundle, appName: bundle.components(separatedBy: ".").last!,
                          title: title, role: "AXWindow", subrole: subrole, frame: frame,
                          isMinimized: minimized, isFullscreen: fullscreen, appOrder: order)
    }

    /// The design's Home Desk: VS Code + Terminal on the LG, Safari ×2 on the Dell, Slack on the MacBook.
    static func homeDeskWindows() -> [LiveWindow] {
        let lg = Fixtures.lg.frame, dell = Fixtures.dell.frame, mb = Fixtures.macbook.frame
        return [
            live("com.microsoft.VSCode", "main.swift — dockstate", Frame(x: lg.x + 20, y: lg.y + 40, width: 1500, height: 1300)),
            live("com.apple.Terminal", "~/dev/dockstate", Frame(x: lg.x + 1560, y: lg.y + 40, width: 900, height: 600)),
            live("com.apple.Safari", "GitHub — Pull requests", Frame(x: dell.x + 10, y: dell.y + 30, width: 1200, height: 1000), order: 0, pid: 3),
            live("com.apple.Safari", "Swift Docs", Frame(x: dell.x + 1220, y: dell.y + 30, width: 690, height: 1000), order: 1, pid: 3),
            live("com.tinyspeck.slackmacgap", "dockstate-dev", Frame(x: mb.x + 20, y: mb.y + 30, width: 760, height: 900)),
        ]
    }

    static func save(_ windows: [LiveWindow], titles: Bool = true) -> Workspace {
        WorkspaceCapture.capture(name: "Home Desk", displays: Fixtures.homeDisplays, windows: windows, includeTitles: titles)
    }

    /// What macOS does when the external displays go away: everything piles onto the laptop.
    static func cascadeOntoLaptop(_ windows: [LiveWindow]) -> [LiveWindow] {
        let mb = Fixtures.macbook.frame
        return windows.enumerated().map { i, w in
            var c = w
            c.frame = Frame(x: mb.x + 30 + Double(i) * 30, y: mb.y + 40 + Double(i) * 30, width: min(w.frame.width, 1200), height: min(w.frame.height, 800))
            return c
        }
    }

    static func running(_ windows: [LiveWindow]) -> Set<String> { Set(windows.map(\.bundleID)) }
}

@Suite struct CaptureTests {
    @Test func capturesStandardWindowsRelativeToTheirDisplay() {
        var windows = Scenario.homeDeskWindows()
        windows.append(Scenario.live("com.apple.Safari", "Prefs", Frame(x: 100, y: 100, width: 300, height: 200), subrole: "AXDialog"))
        windows.append(Scenario.live("com.apple.Notes", "Hidden", Frame(x: 100, y: 100, width: 300, height: 200), minimized: true))
        let ws = Scenario.save(windows)
        #expect(ws.windows.count == 5)
        let vscode = ws.windows.first { $0.bundleID == "com.microsoft.VSCode" }!
        #expect(vscode.displayID == "LG")
        #expect(vscode.frameInDisplay == Frame(x: 20, y: 40, width: 1500, height: 1300))
        #expect(ws.windows.first { $0.appName == "slackmacgap" }?.displayID == "MB")
    }

    @Test func titlesAreOnlyStoredWhenAllowed() {
        let ws = Scenario.save(Scenario.homeDeskWindows(), titles: false)
        #expect(ws.windows.allSatisfy { $0.title == nil })
    }
}

@Suite struct WindowMatcherTests {
    @Test func uniqueWindowMatchesEvenWhenTitleChanged() {
        let original = Scenario.homeDeskWindows()
        let ws = Scenario.save(original)
        var now = Scenario.cascadeOntoLaptop(original)
        now[1].title = "vim — something else"
        let outcomes = WindowMatcher.match(saved: ws.windows, live: now, runningBundleIDs: Scenario.running(now), expectedDisplays: [:])
        let terminal = ws.windows.first { $0.bundleID == "com.apple.Terminal" }!
        #expect(outcomes[terminal.id] == .matched(now[1]))
    }

    @Test func multipleWindowsOfOneAppMatchByTitle() {
        let original = Scenario.homeDeskWindows()
        let ws = Scenario.save(original)
        // Bring the Docs window to front; z-order flipped, sizes now identical.
        var now = Scenario.cascadeOntoLaptop(original)
        now[2].appOrder = 1; now[3].appOrder = 0
        now[3].frame.size(1200, 800); now[2].frame.size(1200, 800)
        let outcomes = WindowMatcher.match(saved: ws.windows, live: now, runningBundleIDs: Scenario.running(now), expectedDisplays: [:])
        let github = ws.windows.first { $0.title == "GitHub — Pull requests" }!
        let docs = ws.windows.first { $0.title == "Swift Docs" }!
        #expect(outcomes[github.id] == .matched(now[2]))
        #expect(outcomes[docs.id] == .matched(now[3]))
    }

    @Test func indistinguishableWindowsAreSkippedNotGuessed() {
        // Titles off, same size, same display: no way to know which Safari window is which.
        let a = Scenario.live("com.apple.Safari", "A", Frame(x: 0, y: 30, width: 1000, height: 800), order: 0, pid: 3)
        let b = Scenario.live("com.apple.Safari", "B", Frame(x: 1100, y: 30, width: 1000, height: 800), order: 1, pid: 3)
        let ws = WorkspaceCapture.capture(name: "x", displays: [Fixtures.lg], windows: [a, b], includeTitles: false)
        var a2 = a, b2 = b
        a2.frame.origin(200, 200); b2.frame.origin(220, 220)
        a2.appOrder = 1; b2.appOrder = 0
        let outcomes = WindowMatcher.match(saved: ws.windows, live: [a2, b2], runningBundleIDs: ["com.apple.Safari"],
                                           expectedDisplays: ["LG": Fixtures.lg.frame])
        #expect(ws.windows.allSatisfy { outcomes[$0.id] == .ambiguous })
    }

    @Test func newWindowOpenedAfterSnapshotDoesNotStealThePlace() {
        let original = [Scenario.live("com.apple.Safari", "GitHub — Pull requests", Frame(x: 2570, y: 230, width: 1200, height: 1000), pid: 3)]
        let ws = Scenario.save(original)
        var moved = original[0]; moved.frame.origin(-1400, 400); moved.appOrder = 1
        let newer = Scenario.live("com.apple.Safari", "Untitled", Frame(x: -1300, y: 420, width: 1200, height: 1000), order: 0, pid: 3)
        let outcomes = WindowMatcher.match(saved: ws.windows, live: [moved, newer], runningBundleIDs: ["com.apple.Safari"], expectedDisplays: [:])
        #expect(outcomes[ws.windows[0].id] == .matched(moved))
    }

    @Test func closedWindowIsNotFoundAndAppNotRunningIsReported() {
        let original = Scenario.homeDeskWindows()
        let ws = Scenario.save(original)
        let now = original.filter { $0.bundleID != "com.apple.Terminal" && $0.title != "Swift Docs" }
        var running = Scenario.running(now)
        running.insert("com.apple.Safari")
        let outcomes = WindowMatcher.match(saved: ws.windows, live: now, runningBundleIDs: running, expectedDisplays: [:])
        #expect(outcomes[ws.windows.first { $0.bundleID == "com.apple.Terminal" }!.id] == .appNotRunning)
        // With titles, the remaining Safari window is still confidently GitHub.
        #expect(outcomes[ws.windows.first { $0.title == "GitHub — Pull requests" }!.id] == .matched(now.first { $0.bundleID == "com.apple.Safari" }!))
        #expect(outcomes[ws.windows.first { $0.title == "Swift Docs" }!.id] == .notFound)
    }

    @Test func assignmentSolverFindsOptimum() {
        // Greedy would take 10 first and end at 10+1; optimum is 9+9.
        let result = Assignment.solve([[10, 9], [9, 1]])
        #expect(result == [1, 0])
        #expect(Assignment.solve([[nil, 5], [nil, nil]]) == [1, nil])
        #expect(Assignment.solve([[3], [7], [5]]) == [nil, 0, nil])
    }
}

@Suite struct RestorePlannerTests {
    @Test func reconnectingHomeDeskMovesEverythingBack() {
        let original = Scenario.homeDeskWindows()
        let ws = Scenario.save(original)
        let now = Scenario.cascadeOntoLaptop(original)
        let plan = RestorePlanner.plan(workspace: ws, currentDisplays: Fixtures.homeDisplays, liveWindows: now,
                                       runningBundleIDs: Scenario.running(now), missingDisplayPolicy: .leaveInPlace)
        #expect(plan.displayMatch.quality == .exact)
        #expect(plan.moves.count == 5)
        #expect(plan.skipped.isEmpty)
        for item in plan.moves {
            guard case .move(let w, let target, _) = item.kind else { continue }
            let originalFrame = original.first { $0.id == w.id }!.frame
            #expect(target == originalFrame)
        }
    }

    @Test func windowsAlreadyInPlaceAreNotMoved() {
        let original = Scenario.homeDeskWindows()
        let ws = Scenario.save(original)
        var now = original
        now[0].frame.origin(5, 5)
        let plan = RestorePlanner.plan(workspace: ws, currentDisplays: Fixtures.homeDisplays, liveWindows: now,
                                       runningBundleIDs: Scenario.running(now), missingDisplayPolicy: .leaveInPlace)
        #expect(plan.moves.count == 1)
        #expect(plan.inPlace.count == 4)
    }

    @Test func missingDisplayFollowsPolicy() {
        let original = Scenario.homeDeskWindows()
        let ws = Scenario.save(original)
        let now = Scenario.cascadeOntoLaptop(original)
        var laptop = Fixtures.macbook; laptop.isMain = true
        let leave = RestorePlanner.plan(workspace: ws, currentDisplays: [laptop], liveWindows: now,
                                        runningBundleIDs: Scenario.running(now), missingDisplayPolicy: .leaveInPlace)
        #expect(leave.displayMatch.quality == .partial)
        #expect(leave.skipped.filter { $0.skipReason == .displayMissing }.count == 4)
        let main = RestorePlanner.plan(workspace: ws, currentDisplays: [laptop], liveWindows: now,
                                       runningBundleIDs: Scenario.running(now), missingDisplayPolicy: .useMainDisplay)
        #expect(main.skipped.isEmpty)
        for item in main.moves {
            guard case .move(_, let target, let display) = item.kind else { continue }
            #expect(display == "MB")
            #expect(target.x >= laptop.frame.x && target.maxX <= laptop.frame.maxX + 0.001)
            #expect(target.y >= laptop.visibleFrame.y && target.maxY <= laptop.frame.maxY + 0.001)
        }
    }

    @Test func minimizedFullscreenAndExcludedWindows() {
        let original = Scenario.homeDeskWindows()
        var ws = Scenario.save(original)
        ws.windows[4].isExcluded = true
        var now = Scenario.cascadeOntoLaptop(original)
        now[0].isMinimized = true
        now[1].isFullscreen = true
        let plan = RestorePlanner.plan(workspace: ws, currentDisplays: Fixtures.homeDisplays, liveWindows: now,
                                       runningBundleIDs: Scenario.running(now), missingDisplayPolicy: .leaveInPlace)
        #expect(plan.items.count == 4)
        #expect(plan.skipped.map(\.skipReason) == [.minimized, .fullscreen])
        #expect(plan.moves.count == 2)
    }

    @Test func resolutionChangeKeepsProportions() {
        var lg = Fixtures.lg
        let saved = Frame(x: 0, y: 25, width: 1280, height: 1415) // left half of the usable area
        lg.frame = Frame(x: 0, y: 0, width: 1920, height: 1080)
        lg.visibleFrame = Frame(x: 0, y: 25, width: 1920, height: 1055)
        let target = Placement.target(for: saved, from: Fixtures.lg, onto: lg)
        #expect(abs(target.width - 960) < 0.5)
        #expect(abs(target.height - 1055) < 0.5)
        #expect(target.x == 0 && target.y == 25)
    }

    @Test func rearrangedDisplaysFollowTheDisplay() {
        let original = Scenario.homeDeskWindows()
        let ws = Scenario.save(original)
        var dell = Fixtures.dell
        dell.frame = Frame(x: -1920, y: -1080, width: 1920, height: 1080)
        dell.visibleFrame = dell.frame
        let plan = RestorePlanner.plan(workspace: ws, currentDisplays: [Fixtures.macbook, Fixtures.lg, dell],
                                       liveWindows: original, runningBundleIDs: Scenario.running(original),
                                       missingDisplayPolicy: .leaveInPlace)
        let safariMoves = plan.moves.filter { $0.saved.bundleID == "com.apple.Safari" }
        #expect(safariMoves.count == 2)
        for item in safariMoves {
            guard case .move(_, let target, _) = item.kind else { continue }
            #expect(target.x < 0 && target.y < 0)
        }
    }
}

@Suite struct RestoreExecutorTests {
    func setup() -> (Workspace, [LiveWindow], RestorePlan) {
        let original = Scenario.homeDeskWindows()
        let ws = Scenario.save(original)
        let now = Scenario.cascadeOntoLaptop(original)
        let plan = RestorePlanner.plan(workspace: ws, currentDisplays: Fixtures.homeDisplays, liveWindows: now,
                                       runningBundleIDs: Scenario.running(now), missingDisplayPolicy: .leaveInPlace)
        return (ws, now, plan)
    }

    @Test func partialFailureDoesNotStopOthers() async {
        let (_, now, plan) = setup()
        let server = FakeWindowServer(now)
        await server.fail(now[0].id)
        await server.close(now[1].id)
        let result = await RestoreExecutor.execute(plan, mover: server)
        #expect(result.movedCount == 3)
        #expect(Set(result.notRestored.map(\.reason)) == [.moveFailed, .windowNotFound])
        #expect(result.undo.entries.count == 3)
    }

    @Test func undoRestoresPreviousFrames() async {
        let (_, now, plan) = setup()
        let server = FakeWindowServer(now)
        let result = await RestoreExecutor.execute(plan, mover: server)
        let undo = await RestoreExecutor.undo(result.undo, mover: server)
        #expect(undo.restoredCount == 5)
        for w in now { #expect(await server.frame(of: w.id) == w.frame) }
    }

    @Test func undoRespectsWindowsTheUserMovedOrClosed() async {
        let (_, now, plan) = setup()
        let server = FakeWindowServer(now)
        let result = await RestoreExecutor.execute(plan, mover: server)
        let userFrame = Frame(x: 5, y: 5, width: 500, height: 500)
        await server.userMoves(now[0].id, to: userFrame)
        await server.close(now[1].id)
        let undo = await RestoreExecutor.undo(result.undo, mover: server)
        #expect(undo.restoredCount == 3)
        #expect(undo.changedSinceCount == 1)
        #expect(undo.goneCount == 1)
        #expect(await server.frame(of: now[0].id) == userFrame)
    }

    @Test func minimumSizeConstraintStillUndoable() async {
        let (_, now, plan) = setup()
        let server = FakeWindowServer(now)
        await server.setMinimum(now[1].id, 1000, 700)
        let result = await RestoreExecutor.execute(plan, mover: server)
        let entry = result.undo.entries.first { $0.window == now[1].id }!
        #expect(entry.after.width == 1000)
        let undo = await RestoreExecutor.undo(result.undo, mover: server)
        #expect(undo.restoredCount == 5)
    }

    @Test func noMovesWhenEverythingInPlace() async {
        let original = Scenario.homeDeskWindows()
        let ws = Scenario.save(original)
        let plan = RestorePlanner.plan(workspace: ws, currentDisplays: Fixtures.homeDisplays, liveWindows: original,
                                       runningBundleIDs: Scenario.running(original), missingDisplayPolicy: .leaveInPlace)
        let server = FakeWindowServer(original)
        let result = await RestoreExecutor.execute(plan, mover: server)
        #expect(result.movedCount == 0)
        #expect(await server.moveCount == 0)
    }
}

extension Frame {
    mutating func size(_ w: Double, _ h: Double) { width = w; height = h }
    mutating func origin(_ nx: Double, _ ny: Double) { x = nx; y = ny }
}

@Suite struct MissingAppsTests {
    @Test func listsEachMissingAppOnce() {
        let original = Scenario.homeDeskWindows()
        let ws = Scenario.save(original)
        // Safari (two windows) and Terminal were quit.
        let now = original.filter { $0.bundleID != "com.apple.Safari" && $0.bundleID != "com.apple.Terminal" }
        let plan = RestorePlanner.plan(workspace: ws, currentDisplays: Fixtures.homeDisplays, liveWindows: now,
                                       runningBundleIDs: Scenario.running(now), missingDisplayPolicy: .leaveInPlace)
        #expect(plan.missingApps == ["com.apple.Terminal", "com.apple.Safari"])
    }

    @Test func excludedWindowsDontCount() {
        let original = Scenario.homeDeskWindows()
        var ws = Scenario.save(original)
        for i in ws.windows.indices where ws.windows[i].bundleID == "com.apple.Terminal" { ws.windows[i].isExcluded = true }
        let now = original.filter { $0.bundleID != "com.apple.Terminal" }
        let plan = RestorePlanner.plan(workspace: ws, currentDisplays: Fixtures.homeDisplays, liveWindows: now,
                                       runningBundleIDs: Scenario.running(now), missingDisplayPolicy: .leaveInPlace)
        #expect(plan.missingApps.isEmpty)
    }
}
