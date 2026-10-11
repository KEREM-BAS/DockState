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

    /// Opens System Settings › Privacy & Security › Accessibility (named "Device Control
    /// and Data Access" since macOS 27).
    public static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// macOS 27 renamed the Accessibility list to "Device Control and Data Access".
    public static var paneIsNamedDeviceControl: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
    }

    /// Removes this app's entry from the list. macOS keeps one entry per bundle ID, tied to
    /// the signature it approved, so after another build of the app (a different signature)
    /// the switch can look on while this build isn't trusted. Resetting needs no password;
    /// `requestPrompt()` adds the app back afterwards.
    public nonisolated static func reset(bundleID: String) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            process.arguments = ["reset", "Accessibility", bundleID]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus == 0) }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: false)
            }
        }
    }

    /// Posted by the system when any app's accessibility trust changes.
    public static let changedNotification = Notification.Name("com.apple.accessibility.api")
}
