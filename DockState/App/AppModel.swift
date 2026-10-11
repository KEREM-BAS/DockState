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
    /// Workspaces the user restored, with the display setup it happened on. Their consent
    /// to place late-opening apps lasts while that setup stays connected.
    @ObservationIgnored private var restoredOnSetup: [UUID: String] = [:]

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
    private(set) var isBusy = false {
        didSet {
            // A display change that arrived while DockState was busy is handled now.
            if !isBusy, pendingSettle {
                pendingSettle = false
                Task { await displaysDidSettle() }
            }
        }
    }
    @ObservationIgnored private var pendingSettle = false

    /// The outcome of the last restore, shown in the result card.
    var lastResult: RestoreResult?
    private(set) var undoRecord: UndoRecord?
    /// Workspace removed with "Delete", kept until the toast's Undo expires.
    private var recentlyDeleted: (workspace: Workspace, index: Int, date: Date)?
    /// How long a deleted workspace can be brought back (toast Undo or ⌘Z in Manage).
    static let deleteUndoWindow: TimeInterval = 15

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
        // The arranged desk is the first-run picture: nothing saved yet.
        let arranged = UserDefaults.standard.bool(forKey: "DockStateDemoArranged")
        workspaces = arranged ? [] : DemoData.workspaces()
        liveWindows = DemoData.liveWindows(arranged: arranged)
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
        workspaceCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            Task { @MainActor in
                guard let self, let bundleID else { return }
                await self.placeLateApp(bundleID)
            }
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
            Task { @MainActor in
                self?.checkPermission()
                await self?.refreshIfStale()
            }
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
        system.prune(keepingPIDs: Set(apps.map(\.pid)))
    }

    @ObservationIgnored private var lastBackgroundRefresh = Date.distantPast

    /// Keeps the menu bar dot honest after the user moves windows by hand: when they switch
    /// apps, rescan at most every 15 seconds, and only if a recognised workspace exists.
    /// Nothing runs while the user is idle.
    func refreshIfStale() async {
        guard permissionGranted, !isBusy, recognized != nil,
              Date().timeIntervalSince(lastBackgroundRefresh) > 15 else { return }
        lastBackgroundRefresh = Date()
        await refresh()
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

    var needsAttention: Bool { menuBarState != .normal && menuBarState != .restoring }

    var menuBarState: MenuBarState {
        if isBusy { return .restoring }
        if settings.hasCompletedOnboarding && !permissionGranted { return .needsPermission }
        let n = outOfPlaceCount
        return n > 0 ? .outOfPlace(n) : .normal
    }

    /// Runs once displays have been stable for a moment after a change or wake.
    ///
    /// Acts only when the display setup actually changed since the last time: a wake,
    /// unlock or Dock change on the same desk never moves windows or posts a notification.
    func displaysDidSettle(afterWakeRecheck: Bool = false) async {
        await refresh()
        // External displays behind docks can appear seconds after wake. If not every display
        // from before sleep is back yet, give them one more chance before treating the
        // smaller setup as a change (which could trigger a pointless restore).
        if !afterWakeRecheck, let wake = lastWake, Date().timeIntervalSince(wake) < 15,
           !Set(displaysBeforeSleep.map(\.id)).isSubset(of: Set(displays.map(\.id))) {
            try? await Task.sleep(for: .seconds(5))
            await displaysDidSettle(afterWakeRecheck: true)
            return
        }

        let key = displays.setupKey
        let changed = key != lastHandledSetupKey
        let previousKey = lastHandledSetupKey
        lastHandledSetupKey = key
        if changed {
            // Consent to place late-opening apps belongs to one connection of a desk.
            restoredOnSetup = restoredOnSetup.filter { $0.value == key }
        }
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
            guard let ws = candidate?.workspace else { break }
            if isBusy {
                // Try again when the current operation ends, against the displays then.
                lastHandledSetupKey = previousKey
                pendingSettle = true
            } else {
                await restore(ws, automatic: true)
            }
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
        recentlyDeleted = nil
        let saved = persist()
        presenter?.requestNotificationPermissionIfNeeded()
        if announce && saved {
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

    // MARK: - Export / import

    func exportData() throws -> Data {
        try WorkspaceTransfer.export(workspaces, includeTitles: settings.useWindowTitles)
    }

    /// Adds the workspaces in `data` next to the existing ones. Returns how many were
    /// added, or nil when they couldn't be saved (the user was told why).
    func importWorkspaces(from data: Data) throws -> Int? {
        let imported = try WorkspaceTransfer.decode(data)
        workspaces = WorkspaceTransfer.merge(imported, into: workspaces, includeTitles: settings.useWindowTitles)
        recentlyDeleted = nil
        return persist() ? imported.count : nil
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
        let keepExcluded = workspace.liveIDsOfExcludedWindows(in: liveWindows, currentDisplays: displays,
                                                              runningBundleIDs: runningBundleIDs)
        let previous = workspace
        guard saveCurrentLayout(named: workspace.name, markExcluded: keepExcluded, announce: false) != nil,
              !storeIsReadOnly else { return }
        presenter?.toast(String(localized: "Updated “\(workspace.name)”"), actionTitle: String(localized: "Undo")) { [weak self] in
            self?.revert(to: previous)
        }
    }

    enum RenameResult { case renamed, unchanged, empty, nameTaken }

    @discardableResult
    func rename(_ target: Workspace, to newName: String) -> RenameResult {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .empty }
        guard name != target.name else { return .unchanged }
        if let clash = workspace(named: name), clash.id != target.id {
            presenter?.toast(String(localized: "A workspace named “\(name)” already exists."))
            return .nameTaken
        }
        var ws = target
        ws.name = name
        recentlyDeleted = nil
        replace(ws, touch: false)
        return .renamed
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
        recentlyDeleted = (workspace, index, Date())
        workspaces.remove(at: index)
        restoredOnSetup[workspace.id] = nil
        guard persist() else { return }
        presenter?.toast(String(localized: "Deleted “\(workspace.name)”"), actionTitle: String(localized: "Undo")) { [weak self] in
            self?.undoDelete()
        }
    }

    /// Only right after deleting — never a workspace deleted long ago.
    var canUndoDelete: Bool {
        guard let deleted = recentlyDeleted else { return false }
        return Date().timeIntervalSince(deleted.date) < Self.deleteUndoWindow
    }

    func undoDelete() {
        guard canUndoDelete, let deleted = recentlyDeleted else { return }
        var ws = deleted.workspace
        let index = deleted.index
        recentlyDeleted = nil
        if workspace(named: ws.name) != nil {
            // A new workspace took the name meanwhile; keep both.
            let base = ws.name
            var n = 2
            while workspace(named: "\(base) (\(n))") != nil { n += 1 }
            ws.name = "\(base) (\(n))"
        }
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

    /// Writes the workspaces. Returns false when they were not saved; the user has then
    /// already been told why, so callers must not show a success message.
    @discardableResult
    private func persist(quiet: Bool = false) -> Bool {
        guard let store else { return true }
        guard !storeIsReadOnly else {
            log.info("Not saving: workspace file is read-only")
            if !quiet { showReadOnlyMessage() }
            return false
        }
        do {
            try store.save(settings.useWindowTitles ? workspaces : workspaces.map { $0.strippingTitles() })
            return true
        } catch {
            log.error("Saving workspaces failed: \(error.localizedDescription, privacy: .public)")
            if !quiet { presenter?.toast(String(localized: "Couldn’t save workspaces to disk.")) }
            return false
        }
    }

    private func showReadOnlyMessage() {
        if case .corrupted = storeIssue {
            presenter?.toast(String(localized: "Changes aren’t saved: the damaged workspace file couldn’t be backed up."))
        } else {
            presenter?.toast(String(localized: "Changes aren’t saved: the workspace file is from a newer DockState."),
                             actionTitle: String(localized: "Convert…")) { [weak self] in
                self?.presenter?.reviewStoreIssue()
            }
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
        restoredOnSetup[workspace.id] = displays.setupKey
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
        // Join the undo record only if it belongs to the result on screen; never extend an
        // older restore's record (the card's Undo would then revert that one too).
        if var record = undoRecord, let last = lastResult, record.workspaceID == workspace.id,
           record.date == last.undo.date {
            record.entries += result.undo.entries
            undoRecord = record
        } else if !result.undo.entries.isEmpty {
            undoRecord = result.undo
        }
        if var last = lastResult, last.workspaceID == workspace.id {
            last.movedCount += result.movedCount
            last.notRestored.removeAll { $0.saved.bundleID == bundleID }
            last.notRestored += result.notRestored
            // The card's Undo covers what was placed here (and the restore it extends).
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

    /// The workspace whose windows should be placed when an app opens later, if any.
    ///
    /// Only for the recognised workspace, and only when the user agreed to have windows
    /// moved: it is set to "Always restore", or they restored it on this display setup.
    func workspaceForLateApps() -> Workspace? {
        guard settings.hasCompletedOnboarding, permissionGranted, let ws = recognized?.workspace else { return nil }
        let allowed = LatePlacementPolicy.allows(enabled: settings.placeLateApps, mode: ws.autoMode,
                                                 restoredOnSetup: restoredOnSetup[ws.id], currentSetup: displays.setupKey)
        return allowed ? ws : nil
    }

    /// Places the windows of an app that was opened after its workspace was restored.
    func placeLateApp(_ bundleID: String) async {
        guard let ws = workspaceForLateApps(),
              ws.windows.contains(where: { $0.bundleID == bundleID && !$0.isExcluded }) else { return }
        let expected = ws.windows.filter { $0.bundleID == bundleID && !$0.isExcluded }.count
        await waitForWindows([bundleID: expected])
        // Re-check after waiting: displays, settings or workspaces may have changed.
        guard !isBusy, let current = workspaceForLateApps(), current.id == ws.id else { return }
        var subset = current
        subset.windows = current.windows.filter { $0.bundleID == bundleID }
        let plan = plan(for: subset)
        guard !plan.moves.isEmpty else { return }
        isBusy = true
        let result = await RestoreExecutor.execute(plan, mover: windowSystem, automatic: true)
        isBusy = false
        guard !result.undo.entries.isEmpty else { return }
        settled.merge(result.undo.settledPlacements) { _, new in new }
        // Its own undo: the restore the user did stays undoable from its card and the menu.
        let record = result.undo
        let appName = plan.moves.first?.saved.appName ?? bundleID
        await refresh()
        presenter?.toast(String(localized: "Placed \(appName) for “\(current.name)”"), actionTitle: String(localized: "Undo")) { [weak self] in
            Task { await self?.undo(record) }
        }
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

    /// Undoes one specific record (the late-placement toast) without touching the restore's.
    private func undo(_ record: UndoRecord) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        _ = await RestoreExecutor.undo(record, mover: windowSystem)
        await refresh()
    }

    func undoLastRestore() async {
        guard let record = undoRecord, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        let result = await RestoreExecutor.undo(record, mover: windowSystem)
        undoRecord = nil
        lastResult = nil
        // Undoing withdraws the consent to place apps opened later.
        restoredOnSetup[record.workspaceID] = nil
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
    /// Explains a read-only workspace file and offers to convert it.
    func reviewStoreIssue()
    func notifyMatch(workspace: Workspace, moves: Int)
    func notifyNewSetup()
    func notifyUpdate(version: String, url: URL)
    func requestNotificationPermissionIfNeeded()
}

extension Presenter {
    func toast(_ message: String) { toast(message, actionTitle: nil, action: nil) }
}
