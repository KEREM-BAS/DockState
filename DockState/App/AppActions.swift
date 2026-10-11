import AppKit
import Observation
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
import Carbon.HIToolbox
import DockStateCore
import DockStateSystem

/// Navigation and commands shared by the popover, windows, notifications and shortcuts.
@MainActor
@Observable
final class AppActions {
    @ObservationIgnored let model: AppModel
    @ObservationIgnored private lazy var router = WindowRouter { [weak self] in
        self?.model.settings.keepWindowsOnTop ?? false
    }

    /// Applies "Keep DockState windows on top" to the windows already open.
    func applyWindowLevels() { router.applyLevels() }

    /// Sparkle's windows and alerts float and keep DockState in Cmd+Tab like its own.
    func adoptOtherWindows() { router.adoptOtherWindows() }

    /// Opens a link (GitHub, the release page) so the browser isn't hidden underneath
    /// DockState's on-top windows.
    func openExternal(_ url: URL) {
        router.lowerUntilReactivated()
        NSWorkspace.shared.open(url)
    }
    /// In-app updates (Sparkle); started once onboarding is done.
    @ObservationIgnored let updater = AppUpdater()

    /// Which workspace the Manage window shows.
    var manageSelection: UUID?
    /// Which workspace the preview window shows.
    var previewWorkspaceID: UUID?
    var settingsTab: SettingsTab = .general
    var onboardingStep: OnboardingStep = .welcome
    /// What the user was trying to do when DockState asked for permission.
    @ObservationIgnored private var pendingAfterPermission: PendingAction?

    init(model: AppModel) {
        self.model = model
    }

    // MARK: Windows

    func showOnboarding(step: OnboardingStep? = nil) {
        closeMenuBarPopover()
        if let step { onboardingStep = step } else if !model.settings.hasCompletedOnboarding { onboardingStep = .welcome }
        router.show(WindowID.onboarding, title: String(localized: "Welcome to DockState"), size: NSSize(width: 640, height: 520),
                    style: [.titled, .closable, .fullSizeContentView], titleVisible: false,
                    onClose: { [weak self] in self?.finishOnboarding() }) {
            OnboardingView().environment(model).environment(self)
        }
    }

    func finishOnboarding() {
        let wasCompleted = model.settings.hasCompletedOnboarding
        model.settings.hasCompletedOnboarding = true
        // Closed without allowing it: later launches don't open the permission step again.
        if !model.permissionGranted { model.settings.permissionDeclined = true }
        model.stopWatchingPermission()
        router.close(WindowID.onboarding)
        // The launch skips the store alert during onboarding; show it once onboarding ends.
        if !wasCompleted, model.storeIsReadOnly, let issue = model.storeIssue { reportStoreIssue(issue) }
        // Sparkle may ask (once) whether to check for updates: right after setup, while
        // DockState is still the active app (its question shows on the next run-loop turn).
        updater.start()
    }

    /// Asks for permission and remembers what to do once it's granted.
    func requirePermission(then action: PendingAction?) {
        pendingAfterPermission = action
        showOnboarding(step: .permission)
    }

    func permissionGrantedForExistingUser() {
        let action = pendingAfterPermission
        pendingAfterPermission = nil
        finishOnboarding()
        switch action {
        case .save: showSave()
        case .preview(let id): if let ws = model.workspace(id: id) { showPreview(ws) }
        case .restoreRecognized: restoreRecognized()
        case nil: model.presenter?.toast(String(localized: "DockState can arrange your windows now."))
        }
    }

    func showSave() {
        closeMenuBarPopover()
        guard model.permissionGranted else { requirePermission(then: .save); return }
        Task { await model.refresh() }
        router.show(WindowID.save, title: String(localized: "Save Current Layout"), size: NSSize(width: 420, height: 190)) {
            SaveLayoutView().environment(model).environment(self)
        }
    }

    func closeSave() { router.close(WindowID.save) }

    func showManage(selecting workspace: Workspace? = nil) {
        closeMenuBarPopover()
        if let workspace { manageSelection = workspace.id }
        if manageSelection == nil || model.workspace(id: manageSelection!) == nil {
            manageSelection = model.recognized?.workspace.id ?? model.workspaces.first?.id
        }
        Task { await model.refresh() }
        router.show(WindowID.manage, title: String(localized: "Workspaces"), size: NSSize(width: 900, height: 560), resizable: true) {
            ManageView().environment(model).environment(self)
        }
    }

    func showSettings(tab: SettingsTab? = nil) {
        closeMenuBarPopover()
        if let tab { settingsTab = tab }
        router.show(WindowID.settings, title: String(localized: "Settings"), size: NSSize(width: 520, height: 360)) {
            SettingsView().environment(model).environment(self)
        }
    }

    func showPreview(_ workspace: Workspace) {
        closeMenuBarPopover()
        guard model.permissionGranted else { requirePermission(then: .preview(workspace.id)); return }
        previewWorkspaceID = workspace.id
        Task { await model.refresh() }
        router.show(WindowID.preview, title: String(localized: "Restore \(workspace.name)"), size: NSSize(width: 860, height: 470)) {
            RestorePreviewView().environment(model).environment(self)
        }
    }

    func closePreview() { router.close(WindowID.preview) }

    // MARK: Commands

    func restore(_ workspace: Workspace) {
        closeMenuBarPopover()
        closePreview()
        Task { await model.restore(workspace) }
    }

    /// ⌥⌘R: restore the workspace that matches the connected displays.
    func restoreRecognized() {
        guard model.permissionGranted else { requirePermission(then: .restoreRecognized); return }
        Task {
            await model.refresh()
            if let candidate = model.recognized {
                await model.restore(candidate.workspace)
            } else {
                model.presenter?.toast(String(localized: "No saved workspace matches these displays."))
            }
        }
    }

    func undo() {
        closeMenuBarPopover()
        Task { await model.undoLastRestore() }
    }

    func quit() { NSApp.terminate(nil) }

    /// Shortcuts macOS refused to register.
    var shortcutConflicts: Set<ShortcutAction> = []
    /// The action whose shortcut is being recorded in Settings, if any.
    var recordingAction: ShortcutAction?
    /// Why the last key press couldn't be used, shown under the recorder.
    var recordingProblem: String?
    @ObservationIgnored private var recordingMonitor: Any?
    @ObservationIgnored private var recordingObservers: [NSObjectProtocol] = []

    func installHotKeys() {
        HotKeyCenter.shared.unregisterAll()
        shortcutConflicts = []
        guard model.settings.globalShortcutsEnabled, recordingAction == nil else { return }
        for action in ShortcutAction.allCases {
            guard let combo = model.settings.shortcuts[action] else { continue }
            let ok = HotKeyCenter.shared.register(action.hotKeyID, combo) { [weak self] in self?.perform(action) }
            if !ok { shortcutConflicts.insert(action) }
        }
    }

    /// The shortcut that actually works for `action` (nil when off or refused by macOS).
    func activeShortcut(for action: ShortcutAction) -> KeyCombo? {
        guard model.settings.globalShortcutsEnabled, !shortcutConflicts.contains(action) else { return nil }
        return model.settings.shortcuts[action]
    }

    /// Starts recording a shortcut. DockState's own hot keys are switched off meanwhile —
    /// otherwise pressing one would run its action instead of being recorded. Only key
    /// presses in the Settings window count, and recording stops as soon as that window
    /// or DockState loses focus.
    func startRecording(_ action: ShortcutAction) {
        stopRecording(reinstall: false)
        recordingAction = action
        recordingProblem = nil
        HotKeyCenter.shared.unregisterAll()
        recordingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.window?.identifier?.rawValue == WindowID.settings else { return event }
            return MainActor.assumeIsolated { self?.handleRecording(event) ?? false } ? nil : event
        }
        // Delivered on the main queue.
        let stop: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.stopRecording() }
        }
        let settingsWindow = NSApp.windows.first { $0.identifier?.rawValue == WindowID.settings }
        recordingObservers = [
            NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: settingsWindow, queue: .main, using: stop),
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: settingsWindow, queue: .main, using: stop),
            NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main, using: stop),
        ]
        FloatingPanel.announce(String(localized: "Recording. Press the new shortcut, or Escape to cancel."))
    }

    func stopRecording(reinstall: Bool = true) {
        if let monitor = recordingMonitor { NSEvent.removeMonitor(monitor) }
        recordingMonitor = nil
        recordingObservers.forEach { NotificationCenter.default.removeObserver($0) }
        recordingObservers = []
        let wasRecording = recordingAction != nil
        recordingAction = nil
        if reinstall && wasRecording { installHotKeys() }
    }

    /// Returns true when the event was used by the recorder.
    private func handleRecording(_ event: NSEvent) -> Bool {
        guard let action = recordingAction else { return false }
        switch Int(event.keyCode) {
        case kVK_Escape:
            stopRecording()
            return true
        case kVK_Delete, kVK_ForwardDelete:
            model.settings.shortcuts[action] = nil
            FloatingPanel.announce(String(localized: "Shortcut removed"))
            stopRecording()
            return true
        default:
            break
        }
        switch KeyCombo.from(event: event) {
        case .failure(.tooSimple):
            reject(String(localized: "Use ⌃, or two of ⌘ ⌥ ⌃, so normal typing and app commands keep working."))
        case .failure(.notAKey):
            reject(String(localized: "That key can’t be used in a shortcut."))
        case .success(let combo):
            if let other = ShortcutAction.allCases.first(where: { $0 != action && model.settings.shortcuts[$0] == combo }) {
                reject(String(localized: "Already used for “\(other.title)”."))
            } else if combo.isReservedBySystem {
                reject(String(localized: "macOS already uses this shortcut."))
            } else {
                model.settings.shortcuts[action] = combo
                FloatingPanel.announce(String(localized: "Shortcut set to \(combo.display)"))
                stopRecording()
            }
        }
        return true
    }

    private func reject(_ reason: String) {
        recordingProblem = reason
        NSSound.beep()
        FloatingPanel.announce(reason)
    }

    private func perform(_ action: ShortcutAction) {
        switch action {
        case .save: showSave()
        case .restore: restoreRecognized()
        case .undo: undo()
        }
    }

    func reportStoreIssue(_ issue: StoreLoadIssue) {
        let alert = NSAlert()
        var backup: URL?
        var offersConvert = false
        switch issue {
        case .corrupted(let url?):
            backup = url
            alert.messageText = String(localized: "Saved workspaces couldn’t be read")
            alert.informativeText = String(localized: "The file was damaged, so DockState started fresh. A copy was kept at \(url.path).")
        case .corrupted(nil):
            alert.messageText = String(localized: "Saved workspaces couldn’t be read")
            alert.informativeText = String(localized: "The file is damaged and DockState couldn’t make a backup, so it won’t overwrite it. Changes you make now aren’t saved.")
        case .newerSchema(_, let url):
            backup = url
            offersConvert = true
            alert.messageText = String(localized: "Workspaces were saved by a newer DockState")
            alert.informativeText = url.map { String(localized: "DockState loaded what it could and won’t change the file unless you convert it. A backup was kept at \($0.path).") }
                ?? String(localized: "DockState loaded what it could and won’t change the file unless you convert it.")
        }
        alert.addButton(withTitle: String(localized: "OK"))
        if offersConvert { alert.addButton(withTitle: String(localized: "Convert for This Version")) }
        if backup != nil { alert.addButton(withTitle: String(localized: "Show in Finder")) }
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        let convertButton: NSApplication.ModalResponse = .alertSecondButtonReturn
        let finderButton: NSApplication.ModalResponse = offersConvert ? .alertThirdButtonReturn : .alertSecondButtonReturn
        if offersConvert && response == convertButton {
            model.convertStoreToCurrentVersion()
        } else if response == finderButton, let backup {
            NSWorkspace.shared.activateFileViewerSelecting([backup])
        }
    }

    // MARK: Export / import

    func exportWorkspaces() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = String(localized: "DockState Workspaces") + ".json"
        panel.message = model.settings.useWindowTitles
            ? String(localized: "The file includes window titles. Turn off window titles in Settings › Restore to leave them out.")
            : String(localized: "The file contains your workspaces without window titles.")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.exportData().write(to: url, options: .atomic)
            model.presenter?.toast(String(localized: "Exported \(model.workspaces.count) workspaces"))
        } catch {
            showError(String(localized: "Couldn’t export workspaces"), error.localizedDescription)
        }
    }

    func importWorkspaces() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if let count = try model.importWorkspaces(from: Data(contentsOf: url)) {
                model.presenter?.toast(String(localized: "Imported \(count) workspaces"))
            }
        } catch WorkspaceTransfer.ImportError.empty {
            showError(String(localized: "Nothing to import"), String(localized: "The file doesn’t contain any workspaces."))
        } catch {
            showError(String(localized: "Couldn’t import workspaces"),
                      String(localized: "The file isn’t a DockState workspace export."))
        }
    }

    private func showError(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    // MARK: Login item

    var opensAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                model.presenter?.toast(String(localized: "Couldn’t change the login item: \(error.localizedDescription)"))
            }
        }
    }
}

enum PendingAction {
    case save
    case preview(UUID)
    case restoreRecognized
}

enum OnboardingStep: Int {
    case welcome, permission, firstSave
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, restore, shortcuts, about
    var id: String { rawValue }
}
