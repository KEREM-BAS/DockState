import AppKit
import SwiftUI
import UserNotifications
import os
import DockStateCore
import DockStateSystem

private let log = Logger(subsystem: "app.dockstate", category: "app")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel = {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "DockStateDemo") {
            let model = AppModel(settings: AppSettings(defaults: UserDefaults(suiteName: "dockstate.demo")!), storeURL: nil)
            model.loadDemo()
            return model
        }
        #endif
        return AppModel()
    }()
    lazy var actions = AppActions(model: model)
    private let resultPanel = FloatingPanel()
    private let toastPanel = FloatingPanel()
    #if DEBUG
    private let router = WindowRouter()
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if SelfTest.runIfRequested() { return }
        #endif
        model.presenter = self
        UNUserNotificationCenter.current().delegate = self
        registerNotificationCategories()
        model.start()
        actions.installHotKeys()
        #if DEBUG
        if openDebugWindowFromLaunchArguments() { return }
        #endif
        if !model.settings.hasCompletedOnboarding {
            actions.showOnboarding()
        } else if let issue = model.storeIssue {
            actions.reportStoreIssue(issue)
        }
    }

    #if DEBUG
    /// `-DockStateOpen manage|settings|save|preview|onboarding|permission|firstSave|result`
    /// opens a window directly; used for UI checks and README screenshots.
    private func openDebugWindowFromLaunchArguments() -> Bool {
        guard let target = UserDefaults.standard.string(forKey: "DockStateOpen") else { return false }
        if let tab = UserDefaults.standard.string(forKey: "DockStateTab").flatMap(SettingsTab.init) { actions.settingsTab = tab }
        switch target {
        case "manage": actions.showManage()
        case "settings": actions.showSettings()
        case "save": actions.showSave()
        case "onboarding": actions.showOnboarding(step: .welcome)
        case "permission": actions.showOnboarding(step: .permission)
        case "firstSave": actions.showOnboarding(step: .firstSave)
        case "popover":
            router.show("popover", title: "DockState", size: NSSize(width: 320, height: 400), style: [.titled], titleVisible: false) {
                MenuBarPopover().environment(model).environment(actions)
            }
        case "result":
            model.loadDemoResult()
            showResult()
        case "preview":
            if let ws = model.recognized?.workspace ?? model.workspaces.first { actions.showPreview(ws) }
        default: return false
        }
        return true
    }
    #endif

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Launching DockState again from Finder opens its main window.
        actions.showManage()
        return false
    }
}

// MARK: - Presenter

extension AppDelegate: Presenter {
    func showResult() {
        guard model.lastResult != nil else { return }
        resultPanel.show(placement: .topTrailing, autoHideAfter: .seconds(20)) {
            ResultCard(onClose: { [weak self] in self?.hideResult() })
                .environment(model)
                .environment(actions)
        }
    }

    func hideResult() {
        resultPanel.hide()
    }

    func toast(_ message: String, actionTitle: String?, action: (@MainActor () -> Void)?) {
        toastPanel.show(placement: .bottomCenter, autoHideAfter: .seconds(4.5)) {
            ToastView(message: message, actionTitle: actionTitle) { [weak self] in
                self?.toastPanel.hide()
                action?()
            }
        }
    }

    func notifyMatch(workspace: Workspace, moves: Int) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "\(workspace.name) displays connected")
        content.body = String(localized: "Put \(moves) windows back where you left them?")
        content.categoryIdentifier = Notifications.matchCategory
        content.userInfo = [Notifications.workspaceKey: workspace.id.uuidString]
        post(content, id: "match")
    }

    func notifyNewSetup() {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "New display setup")
        content.body = String(localized: "Once your windows are arranged, save this setup so DockState can restore it next time.")
        content.categoryIdentifier = Notifications.newSetupCategory
        post(content, id: "new-setup")
    }

    func requestNotificationPermissionIfNeeded() {
        Task {
            let center = UNUserNotificationCenter.current()
            guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
    }

    private func post(_ content: UNMutableNotificationContent, id: String) {
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { log.error("Notification failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    private func registerNotificationCategories() {
        let preview = UNNotificationAction(identifier: Notifications.previewAction, title: String(localized: "Preview"), options: [.foreground])
        let restore = UNNotificationAction(identifier: Notifications.restoreAction, title: String(localized: "Restore"), options: [])
        let save = UNNotificationAction(identifier: Notifications.saveAction, title: String(localized: "Save Workspace…"), options: [.foreground])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: Notifications.matchCategory, actions: [restore, preview], intentIdentifiers: []),
            UNNotificationCategory(identifier: Notifications.newSetupCategory, actions: [save], intentIdentifiers: []),
        ])
    }
}

enum Notifications {
    static let matchCategory = "match"
    static let newSetupCategory = "new-setup"
    static let previewAction = "preview"
    static let restoreAction = "restore"
    static let saveAction = "save"
    static let workspaceKey = "workspace"
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let action = response.actionIdentifier
        let category = response.notification.request.content.categoryIdentifier
        let workspaceID = (response.notification.request.content.userInfo[Notifications.workspaceKey] as? String).flatMap(UUID.init)
        await MainActor.run {
            switch (category, action) {
            case (Notifications.matchCategory, Notifications.restoreAction):
                if let id = workspaceID, let ws = model.workspace(id: id) { Task { await model.restore(ws) } }
            case (Notifications.matchCategory, _):
                if let id = workspaceID, let ws = model.workspace(id: id) { actions.showPreview(ws) }
            case (Notifications.newSetupCategory, Notifications.saveAction), (Notifications.newSetupCategory, UNNotificationDefaultActionIdentifier):
                actions.showSave()
            default:
                break
            }
        }
    }
}
