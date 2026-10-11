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

    /// Quits the app, opens `file` again, lets DockState react, and returns the new window.
    private static func relaunch(_ bundleID: String, file: String, name: String, model: AppModel) async -> LiveWindow? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return nil }
        app.terminate()
        for _ in 0..<40 where !app.isTerminated { try? await Task.sleep(for: .milliseconds(250)) }
        NSWorkspace.shared.open(URL(fileURLWithPath: file))
        // Let the window appear first, so "left alone" can be told from "not there yet".
        for _ in 0..<40 {
            await model.refresh()
            if model.liveWindows.contains(where: { $0.bundleID == bundleID && $0.title?.contains(name) == true }) { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        await model.placeLateApp(bundleID)
        await model.refresh()
        return model.liveWindows.first { $0.bundleID == bundleID && $0.title?.contains(name) == true }
    }

    private static func run(bundleID: String) async -> String {
        var log: [String] = []
        func check(_ ok: Bool, _ what: String) { log.append("\(ok ? "PASS" : "FAIL") \(what)") }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dockstate-selftest-\(UUID().uuidString).json")
        let settings = AppSettings(defaults: UserDefaults(suiteName: "dockstate.selftest")!)
        settings.hasCompletedOnboarding = true
        let model = AppModel(settings: settings, storeURL: tmp)
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
        await model.refresh()

        // An excluded window is never planned for a move, even when it is out of place.
        if var excluded = model.workspace(id: ws.id) {
            excluded.windows = excluded.windows.map { var w = $0; w.isExcluded = true; return w }
            await model.refresh()
            let plan = model.plan(for: excluded)
            check(plan.moves.isEmpty, "excluded window is not moved (moves=\(plan.moves.count))")
        }

        var windowID = target.id
        // Late placement: quit the app and open it again. Only with the dedicated test app
        // (or a test document), never with the developer's own windows.
        if let file = UserDefaults.standard.string(forKey: "DockStateSelfTestFile") {
            let name = URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent
            let windowsOfApp = model.liveWindows.filter { $0.bundleID == bundleID && $0.isStandard }
            if windowsOfApp.count == 1, windowsOfApp[0].title?.contains(name) == true {
                // 1. Right after Undo the user has withdrawn consent: nothing may move.
                if let reopened = await relaunch(bundleID, file: file, name: name, model: model) {
                    check(!reopened.frame.isPlacementEquivalent(to: original),
                          "after Undo, an app opened later is left alone (\(reopened.frame))")
                    windowID = reopened.id
                } else {
                    check(false, "relaunched app's window not found")
                }
                // 2. After a restore, an app opened later goes to its saved place.
                if let ws = model.workspace(id: ws.id) { await model.restore(ws) }
                if let reopened = await relaunch(bundleID, file: file, name: name, model: model) {
                    check(reopened.frame.isPlacementEquivalent(to: original), "app opened after a restore was placed (\(reopened.frame))")
                    windowID = reopened.id
                } else {
                    check(false, "relaunched app's window not found")
                }
                // 3. A manual restore opens an app that isn't running and places its window.
                if model.settings.appNotRunningPolicy == .openFirst,
                   let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                    // Move it away first, so an app that reopens where it was can't pass
                    // this check without DockState placing it.
                    _ = await model.windowSystem.setFrame(displaced, of: windowID)
                    try? await Task.sleep(for: .milliseconds(500))
                    app.terminate()
                    for _ in 0..<40 where !app.isTerminated { try? await Task.sleep(for: .milliseconds(250)) }
                    await model.refresh()
                    if let ws = model.workspace(id: ws.id) {
                        check(model.appsToOpen(for: model.plan(for: ws)) == [bundleID], "quit app is listed to open")
                        await model.restore(ws)
                    }
                    await model.refresh()
                    if let reopened = model.liveWindows.first(where: { $0.bundleID == bundleID && $0.title?.contains(name) == true }) {
                        check(reopened.frame.isPlacementEquivalent(to: original), "restore opened the app and placed its window (\(reopened.frame))")
                        check(model.lastResult?.openedApps == [bundleID], "result reports the opened app")
                        windowID = reopened.id
                    } else {
                        // Apps without a document reopen windowless when macOS closes windows on quit.
                        log.append("SKIP open-and-place: the app opened without a window (System Settings › Desktop & Dock › Close windows when quitting an application)")
                    }
                }
            } else {
                log.append("SKIP late placement: \(windowsOfApp.count) windows of the app are open")
            }
        }

        // Put the window back where the user had it.
        _ = await model.windowSystem.setFrame(original, of: windowID)
        try? FileManager.default.removeItem(at: tmp)
        UserDefaults().removePersistentDomain(forName: "dockstate.selftest")
        log.append(log.contains { $0.hasPrefix("FAIL") } ? "RESULT: FAIL" : "RESULT: PASS")
        return log.joined(separator: "\n")
    }
}
#endif
