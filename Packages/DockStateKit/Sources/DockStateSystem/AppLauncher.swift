import AppKit

/// Launches an app that a workspace expects, so its window can be placed.
@MainActor
public enum AppLauncher {
    /// LaunchServices lookups are synchronous; views ask for icons on every render.
    private static var urls: [String: URL?] = [:]
    private static let icons = NSCache<NSString, NSImage>()

    private static func url(for bundleID: String) -> URL? {
        if let cached = urls[bundleID] { return cached }
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        urls[bundleID] = url
        return url
    }

    public static func isInstalled(_ bundleID: String) -> Bool {
        url(for: bundleID) != nil
    }

    public static func launch(_ bundleID: String) async -> Bool {
        urls[bundleID] = nil
        guard let url = url(for: bundleID) else { return false }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
            return true
        } catch {
            return false
        }
    }

    public static func icon(for bundleID: String) -> NSImage? {
        if let cached = icons.object(forKey: bundleID as NSString) { return cached }
        guard let url = url(for: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icons.setObject(icon, forKey: bundleID as NSString)
        return icon
    }

    /// Forgets cached lookups (e.g. after an app was installed or removed).
    public static func clearCache() {
        urls.removeAll()
        icons.removeAllObjects()
    }
}
