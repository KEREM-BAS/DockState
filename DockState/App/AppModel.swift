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
    @ObservationIgnored private var lastPromptedSetupKey: String?

    private(set) var workspaces: [Workspace] = []
    private(set) var displays: [DisplayDescriptor] = []
    private(set) var liveWindows: [LiveWindow] = []
    private(set) var runningApps: [RunningApp] = []
    private(set) var permissionGranted = AccessibilityPermission.isGranted
    private(set) var storeIssue: StoreLoadIssue?
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
            if let issue = result.issue { log.error("Store issue on load: \(String(describing: issue), privacy: .public)") }
        }
        displays = SystemDisplays.current()
    }

    // MARK: - Lifecycle

    func start() {
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
        let granted = AccessibilityPermission.isGranted
        guard granted != permissionGranted else { return }
        permissionGranted = granted
        log.info("Accessibility permission changed: \(granted, privacy: .public)")
        if !granted {
            // Permission was revoked: drop anything that references live windows.
            liveWindows = []
            undoRecord = nil
        }
        Task { await refresh() }
    }

    func requestPermission() {
        if !settings.didPromptForAccessibility {
            settings.didPromptForAccessibility = true
            AccessibilityPermission.requestPrompt()
        }
        AccessibilityPermission.openSystemSettings()
        beginWatchingPermission()
    }

    // MARK: - Scanning

    /// Re-reads displays and windows. Window reads happen off the main thread.
    func refresh() async {
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
            runningBundleIDs: runningBundleIDs, missingDisplayPolicy: settings.missingDisplayPolicy)
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
    func displaysDidSettle() async {
        await refresh()
        guard settings.hasCompletedOnboarding, permissionGranted else { return }
        let key = displays.map(\.id).sorted().joined(separator: "|")

        guard let candidate = recognized else {
            // Unknown setup: suggest saving once per setup, never repeatedly.
            if settings.notifyOnConnect, !workspaces.isEmpty, key != lastPromptedSetupKey {
                lastPromptedSetupKey = key
                presenter?.notifyNewSetup()
            }
            return
        }
        let plan = plan(for: candidate.workspace)
        guard !plan.moves.isEmpty else { return }
        switch candidate.workspace.autoMode {
        case .always:
            await restore(candidate.workspace, automatic: true)
        case .ask:
            if settings.notifyOnConnect, key != lastPromptedSetupKey {
                lastPromptedSetupKey = key
                presenter?.notifyMatch(workspace: candidate.workspace, moves: plan.moves.count)
            }
        case .never:
            break
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
    @discardableResult
    func saveCurrentLayout(named rawName: String, excluding excluded: Set<LiveWindowID> = []) -> Workspace? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        var ws = WorkspaceCapture.capture(
            name: name, displays: displays, windows: liveWindows,
            includeTitles: settings.useWindowTitles, excluding: excluded)
        if let index = workspaces.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) {
            let existing = workspaces[index]
            ws.id = existing.id
            ws.autoMode = existing.autoMode
            ws.createdAt = existing.createdAt
            workspaces[index] = ws
        } else {
            workspaces.append(ws)
        }
        persist()
        presenter?.requestNotificationPermissionIfNeeded()
        return ws
    }

    func updateFromCurrentLayout(_ workspace: Workspace) async {
        await refresh()
        // Keep windows the user excluded excluded.
        let excludedKeys = Set(workspace.windows.filter(\.isExcluded).map { "\($0.bundleID)|\($0.title ?? "")" })
        guard var updated = saveCurrentLayout(named: workspace.name) else { return }
        updated.windows = updated.windows.map { w in
            var w = w
            w.isExcluded = excludedKeys.contains("\(w.bundleID)|\(w.title ?? "")")
            return w
        }
        replace(updated)
        presenter?.toast(String(localized: "Updated “\(workspace.name)”"))
    }

    func rename(_ target: Workspace, to newName: String) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != target.name else { return }
        if let clash = workspace(named: name), clash.id != target.id { return }
        var ws = target
        ws.name = name
        replace(ws)
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

    /// Removes stored titles from every workspace (used when title matching is turned off).
    func purgeTitles() {
        workspaces = workspaces.map { $0.strippingTitles() }
        persist()
    }

    private func replace(_ workspace: Workspace, touch: Bool = true) {
        guard let i = workspaces.firstIndex(where: { $0.id == workspace.id }) else { return }
        var ws = workspace
        if touch { ws.updatedAt = Date() }
        workspaces[i] = ws
        persist()
    }

    private func persist() {
        guard let store else { return }
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

        if settings.appNotRunningPolicy == .openFirst {
            let missingApps = Set(plan.skipped.filter { $0.skipReason == .appNotRunning }.map(\.saved.bundleID))
            if !missingApps.isEmpty {
                for bundleID in missingApps { _ = await AppLauncher.launch(bundleID) }
                await waitForWindows(of: missingApps)
                plan = self.plan(for: workspace)
            }
        }

        let result = await RestoreExecutor.execute(plan, mover: windowSystem, automatic: automatic)
        log.info("Restore: moved \(result.movedCount, privacy: .public), not restored \(result.notRestored.count, privacy: .public)")
        if !result.undo.entries.isEmpty { undoRecord = result.undo }
        lastResult = result
        await refresh()
        presenter?.showResult()
    }

    /// Opens a missing app, waits for its window and places it as part of the last restore.
    func openAndPlace(bundleID: String, workspace: Workspace) async {
        guard await AppLauncher.launch(bundleID) else {
            presenter?.toast(String(localized: "Couldn’t open the app."))
            return
        }
        await waitForWindows(of: [bundleID])
        var ws = workspace
        ws.windows = ws.windows.filter { $0.bundleID == bundleID }
        let plan = plan(for: ws)
        let result = await RestoreExecutor.execute(plan, mover: windowSystem)
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
            lastResult = last
        }
        await refresh()
    }

    private func waitForWindows(of bundleIDs: Set<String>, timeout: Duration = .seconds(8)) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(500))
            await refresh()
            let ready = bundleIDs.allSatisfy { id in liveWindows.contains { $0.bundleID == id && $0.isStandard } }
            if ready { try? await Task.sleep(for: .milliseconds(400)); await refresh(); return }
        }
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
    func notifyMatch(workspace: Workspace, moves: Int)
    func notifyNewSetup()
    func requestNotificationPermissionIfNeeded()
}

extension Presenter {
    func toast(_ message: String) { toast(message, actionTitle: nil, action: nil) }
}
