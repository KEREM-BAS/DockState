#if DEBUG
import AppKit
import DockStateCore
import DockStateSystem

/// End-to-end check against real windows, for development only:
///
///     open -a DockState.app --args -DockStateSelfTest /tmp/dockstate-selftest.txt [-DockStateSelfTestApp com.apple.TextEdit]
///
/// Saves the target app's window, moves it away, restores, verifies, undoes, verifies.
/// Uses a throw-away store so real workspaces are never touched.
@MainActor
enum SelfTest {
    static func runIfRequested() -> Bool {
        guard let output = UserDefaults.standard.string(forKey: "DockStateSelfTest") else { return false }
        let bundleID = UserDefaults.standard.string(forKey: "DockStateSelfTestApp") ?? "com.apple.TextEdit"
        Task {
            let report = await run(bundleID: bundleID)
            try? report.write(toFile: output, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
        return true
    }

    private static func run(bundleID: String) async -> String {
        var log: [String] = []
        func check(_ ok: Bool, _ what: String) { log.append("\(ok ? "PASS" : "FAIL") \(what)") }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dockstate-selftest-\(UUID().uuidString).json")
        let model = AppModel(settings: AppSettings(defaults: UserDefaults(suiteName: "dockstate.selftest")!), storeURL: tmp)
        log.append("Accessibility granted: \(model.permissionGranted)")
        guard model.permissionGranted else { return log.joined(separator: "\n") }

        await model.refresh()
        log.append("Displays: \(model.displays.count), windows seen: \(model.liveWindows.count), capturable: \(model.capturableWindows.count)")
        let apps = Dictionary(grouping: model.capturableWindows, by: \.bundleID).mapValues(\.count)
        log.append("Apps with capturable windows: \(apps.count)")
        guard let target = model.capturableWindows.first(where: { $0.bundleID == bundleID }) else {
            log.append("FAIL no standard window of \(bundleID) on this Space — open one and retry")
            return log.joined(separator: "\n")
        }
        let original = target.frame
        log.append("Target frame: \(original)")

        // Save only the target window so the test never moves anything else.
        let others = Set(model.capturableWindows.filter { $0.id != target.id }.map(\.id))
        guard let ws = model.saveCurrentLayout(named: "SelfTest", excluding: others) else {
            log.append("FAIL could not save"); return log.joined(separator: "\n")
        }
        check(ws.windows.count == 1, "saved exactly one window")

        // Simulate macOS rearranging the window.
        let displaced = original.offsetBy(dx: 120, dy: 90)
        let moved = await model.windowSystem.setFrame(displaced, of: target.id)
        check((try? moved.get()) != nil, "moved window away (\(moved))")
        await model.refresh()

        let plan = model.plan(for: ws)
        check(plan.displayMatch.quality == .exact, "display setup recognised as exact (\(plan.displayMatch.quality))")
        check(plan.moves.count == 1, "plan has one move (moves=\(plan.moves.count) inPlace=\(plan.inPlace.count) skipped=\(plan.skipped.map { $0.skipReason!.rawValue }))")

        await model.restore(ws)
        await model.refresh()
        let restored = await model.windowSystem.frame(of: target.id)
        check(restored.map { $0.isApproximatelyEqual(to: original, tolerance: 2) } ?? false, "restored to original frame (\(restored.map(\.description) ?? "nil"))")
        check(model.lastResult?.movedCount == 1, "result reports 1 moved")
        if let current = model.workspace(id: ws.id) {
            let after = model.plan(for: current)
            check(after.moves.isEmpty, "nothing left to move after restoring (moves=\(after.moves.count))")
        }
        check(model.canUndo, "undo available")

        await model.undoLastRestore()
        let undone = await model.windowSystem.frame(of: target.id)
        check(undone.map { $0.isApproximatelyEqual(to: displaced, tolerance: 2) } ?? false, "undo moved it back to the displaced frame (\(undone.map(\.description) ?? "nil"))")

        // An excluded window is never planned for a move, even when it is out of place.
        if var excluded = model.workspace(id: ws.id) {
            excluded.windows = excluded.windows.map { var w = $0; w.isExcluded = true; return w }
            await model.refresh()
            let plan = model.plan(for: excluded)
            check(plan.moves.isEmpty, "excluded window is not moved (moves=\(plan.moves.count))")
        }

        // Put the window back where the user had it.
        _ = await model.windowSystem.setFrame(original, of: target.id)
        try? FileManager.default.removeItem(at: tmp)
        UserDefaults().removePersistentDomain(forName: "dockstate.selftest")
        log.append(log.contains { $0.hasPrefix("FAIL") } ? "RESULT: FAIL" : "RESULT: PASS")
        return log.joined(separator: "\n")
    }
}
#endif
