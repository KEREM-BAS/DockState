import AppKit
import os
import DockStateCore

private let log = Logger(subsystem: "app.dockstate", category: "updates")

/// Opt-in check for a newer release on GitHub. This is DockState's only network request,
/// and it only happens when the user turned it on or pressed "Check Now". It sends no
/// identifiers — just a plain request for the public list of releases.
@MainActor
final class UpdateChecker {
    enum Outcome: Equatable {
        case upToDate
        case available(version: String, url: URL)
        case failed
    }

    static let releasesURL = URL(string: "https://github.com/KEREM-BAS/DockState/releases.atom")!

    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    static var currentVersion: AppVersion? {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init)
    }

    /// Automatic check: only when enabled and the last check is more than a day old.
    var isDue: Bool {
        guard settings.checkForUpdates else { return false }
        guard let last = settings.lastUpdateCheck else { return true }
        return Date().timeIntervalSince(last) > 24 * 3600
    }

    private var inFlight: Task<Outcome, Never>?
    var isChecking: Bool { inFlight != nil }

    /// Checks GitHub. A check that's already running is joined rather than refused, so an
    /// automatic check and "Check Now" never collide.
    func check() async -> Outcome {
        if let inFlight { return await inFlight.value }
        let task = Task { await self.performCheck() }
        inFlight = task
        let outcome = await task.value
        inFlight = nil
        return outcome
    }

    private func performCheck() async -> Outcome {
        guard let current = Self.currentVersion else {
            log.error("Can't read this build's version")
            return .failed
        }
        var request = URLRequest(url: Self.releasesURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/atom+xml", forHTTPHeaderField: "Accept")
        request.setValue("DockState", forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let releases = UpdateCheck.decodeAtomReleases(data) else { return .failed }
            // Only a check that really read the feed counts toward "once a day".
            settings.lastUpdateCheck = Date()
            if let (release, version) = UpdateCheck.newerRelease(than: current, in: releases) {
                return .available(version: version.description, url: release.htmlURL)
            }
            return .upToDate
        } catch {
            log.error("Update check failed: \(error.localizedDescription, privacy: .public)")
            return .failed
        }
    }
}
