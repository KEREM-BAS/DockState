import AppKit
import ApplicationServices

/// Accessibility (TCC) permission state. macOS has no callback for changes, so the app
/// polls while it is waiting and listens to the system's accessibility notification.
@MainActor
public enum AccessibilityPermission {
    public static var isGranted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt, which also adds DockState to the list in System Settings.
    public static func requestPrompt() {
        let key = "AXTrustedCheckOptionPrompt" as CFString // kAXTrustedCheckOptionPrompt
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Opens System Settings › Privacy & Security › Accessibility.
    public static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Posted by the system when any app's accessibility trust changes.
    public static let changedNotification = Notification.Name("com.apple.accessibility.api")
}
