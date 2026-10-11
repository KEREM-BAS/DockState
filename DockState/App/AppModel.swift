import AppKit
import Observation
import os
import DockStateCore
import DockStateSystem

private let log = Logger(subsystem: "app.dockstate", category: "model")

/// The single source of truth for the app: saved workspaces, the current displays and
/// windows, and the restore/undo lifecycle.
@MainActor
@Observable
final class AppModel {
    let settings: AppSettings
    let windowSystem = AccessibilityWindowSystem()
    @ObservationIgnored private let store: WorkspaceStore?
    @ObservationIgnored private var displayObserver: DisplayChangeObserver?
    @ObservationIgnored private var permissionTimer: Timer?
    /// The display setup DockState last reacted to. Wake, unlock or a moved Dock with the
    /// same setup never trigger a suggestion or an automatic restore.
    @ObservationIgnored private var lastHandledSetupKey: String?
    /// Unknown setups DockState already suggested saving, so it doesn't nag.
    @ObservationIgnored private var suggestedSetupKeys: Set<String> = []
    /// Displays before the Mac went to sleep, to tell a half-woken desk from a new setup.
    @ObservationIgnored private var displaysBeforeSleep: [DisplayDescriptor] = []
    @ObservationIgnored private var lastWake: Date?
    @ObservationIgnored private var refreshChain: Task<Void, Never>?

    private(set) var workspaces: [Workspace] = []
    private(set) var displays: [DisplayDescriptor] = []
    private(set) var liveWindows: [LiveWindow] = []
    private(set) var runningApps: [RunningApp] = []
    private(set) var permissionGranted = AccessibilityPermission.isGranted
    private(set) var storeIssue: StoreLoadIssue?
    /// The workspace file came from a newer DockState (or couldn't be backed up): changes
    /// stay in memory until the user agrees to convert it.
    private(set) var storeIsReadOnly = false
    /// Frames the last restores achieved, so windows that can't take the exact size still
    /// count as in place afterwards.
    @ObservationIgnored private var settled: [LiveWindowID: SettledPlacement] = [:]
    private(set) var isBusy = false

    /// The outcome of the last restore, shown in the result card.
    var lastResult: RestoreResult?
    private(set) var undoRecord: UndoRecord?
    /// Workspace removed with "Delete", kept until the toast's Undo expires.
    @ObservationIgnored private var recentlyDeleted: (workspace: Workspace, index: Int)?

    /// Hooks the UI layer sets up to present windows and transient UI.
    @ObservationIgnored var presenter: Presenter?

    init(settings: AppSettings = AppSettings(), storeURL: URL? = try? WorkspaceStore.defaultURL()) {
        self.settings = settings
        self.store = storeURL.map(WorkspaceStore.init(fileURL:))
        if let store {
            let result = store.load()
            workspaces = result.workspaces
            storeIssue = result.issue
            storeIsReadOnly = result.isReadOnly
            if let issue = result.issue { log.error("Store issue on load: \(String(describing: issue), privacy: .public)") }
        }
        displays = SystemDisplays.current()
    }

    #if DEBUG
    @ObservationIgnored private(set) var isDemo = false

    /// Replaces live data with the fictional desk in `DemoData` (screenshots only).
    func loadDemo() {
        isDemo = true
        displays = DemoData.displays
        workspaces = DemoData.workspaces()
        liveWindows = DemoData.liveWindows(arranged: UserDefaults.standard.bool(forKey: "DockStateDemoArranged"))
        runningApps = DemoData.runningApps()
        permissionGranted = true
        settings.hasCompletedOnboarding = true
    }

    func loadDemoResult() {
        guard let ws = workspaces.first else { return }
        lastResult = DemoData.lastResult(workspace: ws)
        undoRecord = lastResult?.undo
    }
    #endif

    // MARK: - Lifecycle

    func start() {
        // Displays connected at launch are not a change: never auto-restore at login or
        // after DockState relaunches.
        lastHandledSetupKey = displays.setupKey
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.displaysBeforeSleep = self?.displays ?? [] }
        }
        workspaceCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.lastWake = Date() }
        }
        let observer = DisplayChangeObserver { [weak self] in
            Task { await self?.displaysDidSettle() }
        }
        observer.start()
        displayObserver = observer
        DistributedNotificationCenter.default().addObserver(
            forName: AccessibilityPermission.changedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // The trust database updates slightly after the notification.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                self?.checkPermission()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.checkPermission() }
        }
        Task { await refresh() }
    }

    /// Polls while the user is in System Settings; there is no reliable push for TCC changes.
    func beginWatchingPermission() {
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.checkPermission()
                if self.permissionGranted { self.permissionTimer?.invalidate(); self.permissionTimer = nil }
            }
        }
    }

    func checkPermission() {
        #if DEBUG
        if isDemo { return }
        #endif
        let granted = AccessibilityPermission.isGranted
        guard granted != permissionGranted else { return }
        permissionGranted = granted
        log.info("Accessibility permission changed: \(granted, privacy: .public)")
        if !granted {
            // Permission was revoked: drop anything that references live windows.
            liveWindows = []
            undoRecord = nil
            settled = [:]
        }
        Task { await refresh() }
    }

    /// First time: the system prompt (it adds DockState to the list and offers to open
    /// System Settings). After that: open System Settings directly.
    func requestPermission() {
        if !settings.didPromptForAccessibility {
            settings.didPromptForAccessibility = true
            AccessibilityPermission.requestPrompt()
        } else {
            AccessibilityPermission.openSystemSettings()
        }
        beginWatchingPermission()
    }

    func stopWatchingPermission() {
        permissionTimer?.invalidate()
        permissionTimer = nil
    }

    /// The user allowed DockState before, but this build isn't trusted — typical after an
    /// update of an unsigned build: the switch looks on but belongs to the old version.
    var permissionLooksStale: Bool {
        settings.didPromptForAccessibility && !permissionGranted
    }

    // MARK: - Scanning

    /// Re-reads displays and windows. Window reads happen off the main thread.
    ///
    /// Refreshes run one after another, so a slow scan can never overwrite a newer one.
    func refresh() async {
        #if DEBUG
        if isDemo { return }
        #endif
        let previous = refreshChain
        let task = Task { @MainActor [weak self] in
            await previous?.value
            await self?.performRefresh()
        }
        refreshChain = task
        await task.value
    }

    private func performRefresh() async {
        displays = SystemDisplays.current()
        runningApps = AccessibilityWindowSystem.runningApps()
        guard permissionGranted else { liveWindows = []; return }
        let apps = runningApps, system = windowSystem
        liveWindows = await Task.detached(priority: .userInitiated) { system.windows(of: apps) }.value
    }

    var capturableWindows: [LiveWindow] {
        WorkspaceCapture.capturable(liveWindows, displays: displays)
    }

    var runningBundleIDs: Set<String> { Set(runningApps.map(\.bundleID)) }

    // MARK: - Recognition

    var recognized: WorkspaceRecognizer.Candidate? {
        WorkspaceRecognizer.recognized(workspaces, current: displays)
    }

    func plan(for workspace: Workspace) -> RestorePlan {
        RestorePlanner.plan(
            workspace: workspace, currentDisplays: displays, liveWindows: liveWindows,
            runningBundleIDs: runningBundleIDs, missingDisplayPolicy: settings.missingDisplayPolicy,
            settled: settled)
    }

    func match(for workspace: Workspace) -> DisplayMatch {
        DisplayMatcher.match(saved: workspace.displays, current: displays)
    }

    /// Windows of the recognised workspace that are out of place (drives the menu bar badge).
    var outOfPlaceCount: Int {
        guard permissionGranted, let candidate = recognized else { return 0 }
        return plan(for: candidate.workspace).moves.count
    }

    var needsAttention: Bool {
        (settings.hasCompletedOnboarding && !permissionGranted) || outOfPlaceCount > 0
    }

    /// Runs once displays have been stable for a moment after a change or wake.
    ///
    /// Acts only when the display setup actually changed since the last time: a wake,
    /// unlock or Dock change on the same desk never moves windows or posts a notification.
    func displaysDidSettle(afterWakeRecheck: Bool = false) async {
        await refresh()
        // External displays behind docks can appear seconds after wake. If fewer displays
        // are back than before sleep, give them one more chance before treating the
        // smaller setup as a change (which could trigger a pointless restore).
        if !afterWakeRecheck, let wake = lastWake, Date().timeIntervalSince(wake) < 15,
           displays.count < displaysBeforeSleep.count {
            try? await Task.sleep(for: .seconds(5))
            await displaysDidSettle(afterWakeRecheck: true)
            return
        }

        let key = displays.setupKey
        let changed = key != lastHandledSetupKey
        lastHandledSetupKey = key
        let candidate = recognized
        let moves = candidate.map { plan(for: $0.workspace).moves.count } ?? 0
        let action = AutoRestorePolicy.action(for: .init(
            setupChanged: changed, onboardingCompleted: settings.hasCompletedOnboarding,
            permissionGranted: permissionGranted, hasWorkspaces: !workspaces.isEmpty,
            notifyOnConnect: settings.notifyOnConnect, alreadySuggested: suggestedSetupKeys.contains(key),
            recognizedMode: candidate?.workspace.autoMode, outOfPlace: moves))
        switch action {
        case .none:
            break
        case .suggestSaving:
            suggestedSetupKeys.insert(key)
            presenter?.notifyNewSetup()
        case .notifyMatch(let moves):
            if let ws = candidate?.workspace { presenter?.notifyMatch(workspace: ws, moves: moves) }
        case .restoreAutomatically:
            if let ws = candidate?.workspace { await restore(ws, automatic: true) }
        }
    }

    /// The Restore button of a notification. If the displays changed since it was posted,
    /// show the preview instead of restoring blindly.
    func restoreFromNotification(workspaceID: UUID) async {
        await refresh()
        guard let ws = workspace(id: workspaceID) else { return }
        if recognized?.workspace.id == workspaceID {
            await restore(ws)
        } else {
            presenter?.showPreview(ws)
        }
    }

    // MARK: - Saving

    func workspace(id: UUID) -> Workspace? { workspaces.first { $0.id == id } }
    func workspace(named name: String) -> Workspace? {
        let key = name.trimmingCharacters(in: .whitespaces).lowercased()
        return workspaces.first { $0.name.lowercased() == key }
    }

    /// A name suggestion for the current setup.
    func suggestedName() -> String {
        if let candidate = recognized { return candidate.workspace.name }
        let base: String
        if displays.count == 1, displays[0].isBuiltin {
            base = String(localized: "Laptop Only")
        } else {
            base = String(localized: "Home Desk")
        }
        guard workspace(named: base) != nil else { return base }
        var n = workspaces.count + 1
        while workspace(named: String(localized: "Workspace \(n)")) != nil { n += 1 }
        return String(localized: "Workspace \(n)")
    }

    /// Saves (or replaces, when the name exists) a workspace from the current windows.
    ///
    /// Refuses to save a layout without windows — that would silently wipe an existing
    /// workspace (e.g. after permission was revoked or on an empty Space). Replacing an
    /// existing workspace can be undone from the toast.
    @discardableResult
    func saveCurrentLayout(named rawName: String, excluding excluded: Set<LiveWindowID> = [],
                           markExcluded: Set<LiveWindowID> = [], announce: Bool = true) -> Workspace? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, permissionGranted else { return nil }
        var ws = WorkspaceCapture.capture(
            name: name, displays: displays, windows: liveWindows,
            includeTitles: settings.useWindowTitles, excluding: excluded, markExcluded: markExcluded)
        guard !ws.windows.isEmpty else {
            presenter?.toast(String(localized: "No windows to save on this Space."))
            return nil
        }
        var replaced: Workspace?
        if let index = workspaces.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) {
            let existing = workspaces[index]
            replaced = existing
            ws.id = existing.id
            ws.autoMode = existing.autoMode
            ws.createdAt = existing.createdAt
            ws.lastRestoredAt = existing.lastRestoredAt
            workspaces[index] = ws
        } else {
            workspaces.append(ws)
        }
        persist()
        presenter?.requestNotificationPermissionIfNeeded()
        if announce {
            if let replaced {
                presenter?.toast(String(localized: "Replaced “\(ws.name)”"), actionTitle: String(localized: "Undo")) { [weak self] in
                    self?.revert(to: replaced)
                }
            } else {
                presenter?.toast(String(localized: "Saved “\(ws.name)”"))
            }
        }
        return ws
    }

    /// Puts back a previous version of a workspace (undo of a replace or an update).
    private func revert(to previous: Workspace) {
        guard let i = workspaces.firstIndex(where: { $0.id == previous.id }) else { return }
        workspaces[i] = previous
        persist()
    }

    func updateFromCurrentLayout(_ workspace: Workspace) async {
        await refresh()
        // Keep excluded windows excluded, by window identity rather than by title.
        let keepExcluded = workspace.liveIDsOfExcludedWindows(in: liveWindows, runningBundleIDs: runningBundleIDs)
        let previous = workspace
        guard saveCurrentLayout(named: workspace.name, markExcluded: keepExcluded, announce: false) != nil else { return }
        presenter?.toast(String(localized: "Updated “\(workspace.name)”"), actionTitle: String(localized: "Undo")) { [weak self] in
            self?.revert(to: previous)
        }
    }

    func rename(_ target: Workspace, to newName: String) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != target.name else { return }
        if let clash = workspace(named: name), clash.id != target.id { return }
        var ws = target
        ws.name = name
        replace(ws, touch: false)
    }

    func setAutoMode(_ mode: AutoMode, for workspace: Workspace) {
        var ws = workspace
        ws.autoMode = mode
        replace(ws, touch: false)
    }

    func setExcluded(_ excluded: Bool, window: SavedWindow, in workspace: Workspace) {
        var ws = workspace
        guard let i = ws.windows.firstIndex(where: { $0.id == window.id }) else { return }
        ws.windows[i].isExcluded = excluded
        replace(ws, touch: false)
    }

    func delete(_ workspace: Workspace) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspace.id }) else { return }
        recentlyDeleted = (workspace, index)
        workspaces.remove(at: index)
        persist()
        presenter?.toast(String(localized: "Deleted “\(workspace.name)”"), actionTitle: String(localized: "Undo")) { [weak self] in
            self?.undoDelete()
        }
    }

    private func undoDelete() {
        guard let (ws, index) = recentlyDeleted else { return }
        recentlyDeleted = nil
        workspaces.insert(ws, at: min(index, workspaces.count))
        persist()
    }

    private func markRestored(_ workspace: Workspace) {
        guard var ws = self.workspace(id: workspace.id) else { return }
        ws.lastRestoredAt = Date()
        replace(ws, touch: false, quiet: true)
    }

    /// Removes stored titles from every workspace (used when title matching is turned off).
    func purgeTitles() {
        workspaces = workspaces.map { $0.strippingTitles() }
        persist()
    }

    private func replace(_ workspace: Workspace, touch: Bool = true, quiet: Bool = false) {
        guard let i = workspaces.firstIndex(where: { $0.id == workspace.id }) else { return }
        var ws = workspace
        if touch { ws.updatedAt = Date() }
        workspaces[i] = ws
        persist(quiet: quiet)
    }

    /// Allows saving over a workspace file written by a newer DockState (a backup was kept).
    func convertStoreToCurrentVersion() {
        storeIsReadOnly = false
        persist()
    }

    private func persist(quiet: Bool = false) {
        guard let store else { return }
        guard !storeIsReadOnly else {
            log.info("Not saving: workspace file is read-only")
            if quiet { return }
            presenter?.toast(String(localized: "Changes aren’t saved: the workspace file is from a newer DockState."))
            return
        }
        do {
            try store.save(settings.useWindowTitles ? workspaces : workspaces.map { $0.strippingTitles() })
        } catch {
            log.error("Saving workspaces failed: \(error.localizedDescription, privacy: .public)")
            presenter?.toast(String(localized: "Couldn’t save workspaces to disk."))
        }
    }

    // MARK: - Restore & undo

    func restore(_ workspace: Workspace, automatic: Bool = false) async {
        guard permissionGranted, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        await refresh()
        var plan = plan(for: workspace)

        // Apps are only launched when the user restores by hand — an automatic restore
        // must never start apps the user had quit.
        if !automatic, settings.appNotRunningPolicy == .openFirst {
            let missing = plan.skipped.filter { $0.skipReason == .appNotRunning }.map(\.saved.bundleID)
            if !missing.isEmpty {
                var expected: [String: Int] = [:]
                for bundleID in missing { expected[bundleID, default: 0] += 1 }
                for bundleID in expected.keys { _ = await AppLauncher.launch(bundleID) }
                await waitForWindows(expected)
                plan = self.plan(for: workspace)
            }
        }

        let result = await RestoreExecutor.execute(plan, mover: windowSystem, automatic: automatic)
        log.info("Restore: moved \(result.movedCount, privacy: .public), not restored \(result.notRestored.count, privacy: .public)")
        if !result.undo.entries.isEmpty { undoRecord = result.undo }
        settled.merge(result.undo.settledPlacements) { _, new in new }
        lastResult = result
        markRestored(workspace)
        await refresh()
        presenter?.showResult()
    }

    /// Opens a missing app, waits for its window and places it as part of the last restore.
    func openAndPlace(bundleID: String, workspace: Workspace) async {
        guard permissionGranted, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        guard await AppLauncher.launch(bundleID) else {
            presenter?.toast(String(localized: "Couldn’t open the app."))
            return
        }
        let expected = workspace.windows.filter { $0.bundleID == bundleID && !$0.isExcluded }.count
        await waitForWindows([bundleID: max(1, expected)])
        var ws = workspace
        ws.windows = ws.windows.filter { $0.bundleID == bundleID }
        let plan = plan(for: ws)
        let result = await RestoreExecutor.execute(plan, mover: windowSystem)
        settled.merge(result.undo.settledPlacements) { _, new in new }
        if var record = undoRecord, record.workspaceID == workspace.id {
            record.entries += result.undo.entries
            undoRecord = record
        } else if !result.undo.entries.isEmpty {
            undoRecord = result.undo
        }
        if var last = lastResult, last.workspaceID == workspace.id {
            last.movedCount += result.movedCount
            last.notRestored.removeAll { $0.saved.bundleID == bundleID }
            last.notRestored += result.notRestored
            // The card's Undo covers what was placed here too.
            if let record = undoRecord, record.workspaceID == workspace.id { last.undo = record }
            lastResult = last
        }
        await refresh()
    }

    /// Waits until each launched app shows its expected number of standard windows, or
    /// its window count stops growing for a second (apps open restored windows one by
    /// one), at most `timeout`. Only the launched apps are scanned while waiting.
    private func waitForWindows(_ expected: [String: Int], timeout: Duration = .seconds(8)) async {
        let deadline = ContinuousClock.now + timeout
        var lastCounts: [String: Int] = [:]
        var stableSince = ContinuousClock.now
        let system = windowSystem
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(400))
            let apps = AccessibilityWindowSystem.runningApps().filter { expected[$0.bundleID] != nil }
            let windows = await Task.detached(priority: .userInitiated) { system.windows(of: apps) }.value
            var counts: [String: Int] = [:]
            for w in windows where w.isStandard && !w.isMinimized { counts[w.bundleID, default: 0] += 1 }
            if expected.allSatisfy({ counts[$0.key, default: 0] >= $0.value }) { break }
            if counts != lastCounts {
                lastCounts = counts
                stableSince = ContinuousClock.now
            } else if expected.keys.allSatisfy({ counts[$0, default: 0] > 0 }),
                      ContinuousClock.now - stableSince >= .seconds(1) {
                break
            }
        }
        try? await Task.sleep(for: .milliseconds(300))
        await refresh()
    }

    /// Whether "Open & Place" makes sense for a skipped window: the app isn't running, or
    /// it is running without any window (opening it again asks it for a new window).
    func canOpenAndPlace(_ saved: SavedWindow, reason: SkipReason) -> Bool {
        guard AppLauncher.isInstalled(saved.bundleID) else { return false }
        switch reason {
        case .appNotRunning: return true
        case .windowNotFound: return !liveWindows.contains { $0.bundleID == saved.bundleID && $0.isStandard }
        default: return false
        }
    }

    /// Undo in the result card applies to that result only, never to an older restore.
    var canUndoLastResult: Bool {
        guard canUndo, let result = lastResult, !result.undo.entries.isEmpty else { return false }
        return undoRecord?.workspaceID == result.workspaceID && undoRecord?.date == result.undo.date
    }

    var canUndo: Bool { undoRecord != nil && permissionGranted }

    func undoLastRestore() async {
        guard let record = undoRecord, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        let result = await RestoreExecutor.undo(record, mover: windowSystem)
        undoRecord = nil
        lastResult = nil
        presenter?.hideResult()
        await refresh()
        let message: String
        if result.changedSinceCount + result.goneCount > 0 {
            message = String(localized: "\(result.restoredCount) windows moved back.") + " "
                + String(localized: "\(result.changedSinceCount + result.goneCount) had changed and were left alone.")
        } else {
            message = String(localized: "Windows moved back")
        }
        let workspaceID = record.workspaceID
        presenter?.toast(message, actionTitle: String(localized: "Redo")) { [weak self] in
            guard let self, let ws = self.workspace(id: workspaceID) else { return }
            Task { await self.restore(ws) }
        }
    }
}

/// UI hooks the model calls; implemented by the app delegate so the model stays testable.
@MainActor
protocol Presenter: AnyObject {
    func showResult()
    func hideResult()
    func toast(_ message: String, actionTitle: String?, action: (@MainActor () -> Void)?)
    func showPreview(_ workspace: Workspace)
    func notifyMatch(workspace: Workspace, moves: Int)
    func notifyNewSetup()
    func requestNotificationPermissionIfNeeded()
}

extension Presenter {
    func toast(_ message: String) { toast(message, actionTitle: nil, action: nil) }
}
