import AppKit
import Observation
import ServiceManagement
import SwiftUI
import DockStateCore
import DockStateSystem

/// Navigation and commands shared by the popover, windows, notifications and shortcuts.
@MainActor
@Observable
final class AppActions {
    @ObservationIgnored let model: AppModel
    @ObservationIgnored private let router = WindowRouter()

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
        model.settings.hasCompletedOnboarding = true
        model.stopWatchingPermission()
        router.close(WindowID.onboarding)
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

    /// Shortcuts macOS refused because something else already uses them.
    var shortcutConflicts: Set<ShortcutAction> = []

    func installHotKeys() {
        HotKeyCenter.shared.unregisterAll()
        shortcutConflicts = []
        guard model.settings.globalShortcutsEnabled else { return }
        for action in ShortcutAction.allCases {
            guard let combo = model.settings.shortcuts[action] else { continue }
            let ok = HotKeyCenter.shared.register(action.hotKeyID, combo) { [weak self] in self?.perform(action) }
            if !ok { shortcutConflicts.insert(action) }
        }
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
