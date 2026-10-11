import AppKit
import Observation
import Sparkle
import os

private let log = Logger(subsystem: "app.dockstate", category: "updates")

/// In-app updates with Sparkle. Each release publishes the DMG and an `appcast.xml`; Sparkle
/// reads the feed, verifies the update's EdDSA signature and code signature, and installs it.
///
/// Nothing is requested until the user agrees: after setup Sparkle asks once whether to
/// check automatically (once a day). Settings › General changes it any time, and *Check Now*
/// always works.
@MainActor
@Observable
final class AppUpdater: NSObject {
    @ObservationIgnored private var controller: SPUStandardUpdaterController!
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?
    @ObservationIgnored private var updater: SPUUpdater { controller.updater }
    /// Bumped whenever Sparkle's settings may have changed, so views re-read them.
    private var revision = 0
    private(set) var isStarted = false
    private(set) var canCheck = false
    /// A version found by a scheduled check, waiting for the user's attention (shown in the
    /// menu bar panel); nil once they look at it or the update session ends.
    private(set) var availableVersion: String?
    /// Posts and removes the "new version" notification (set by the app delegate).
    @ObservationIgnored var postNotification: ((String) -> Void)?
    @ObservationIgnored var removeNotification: (() -> Void)?

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        canCheckObservation = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            MainActor.assumeIsolated { self?.canCheck = updater.canCheckForUpdates }
        }
    }

    var automaticallyChecks: Bool {
        get {
            _ = revision
            return updater.automaticallyChecksForUpdates
        }
        set {
            updater.automaticallyChecksForUpdates = newValue
            revision += 1
        }
    }

    /// Only possible while automatic checks are on (Sparkle ignores it otherwise).
    var automaticallyDownloads: Bool {
        get {
            _ = revision
            return updater.automaticallyChecksForUpdates && updater.automaticallyDownloadsUpdates
        }
        set {
            updater.automaticallyDownloadsUpdates = newValue
            revision += 1
        }
    }

    var lastCheck: Date? {
        _ = revision
        return updater.lastUpdateCheckDate
    }

    /// Starts Sparkle once DockState is set up (it may ask whether to check automatically,
    /// so not during onboarding). Safe to call more than once.
    func start() {
        guard !isStarted else { return }
        #if DEBUG || UPDATE_TEST
        // Development builds aren't released; only the update test starts the updater.
        guard UpdateTest.isRequested else { return }
        #endif
        migrateLegacySetting()
        do {
            try updater.start()
            isStarted = true
            log.info("Updater started")
        } catch {
            log.error("Updater failed to start: \(error.localizedDescription, privacy: .public)")
        }
        revision += 1
        #if DEBUG || UPDATE_TEST
        if UpdateTest.isRequested { UpdateTest.begin(updater) }
        #endif
    }

    /// *Check Now*, the app menu item, and the menu bar panel's update row (which brings an
    /// update found in the background to the front).
    func checkNow() {
        guard isStarted else { return }
        controller.checkForUpdates(nil)
    }

    #if DEBUG
    /// `-DockStateDemoUpdate <version>`: the reminder row, for screenshots.
    func showDemoReminder(version: String) { availableVersion = version }
    #endif

    /// DockState 0.1 had its own opt-in check; carry that answer over so the user isn't
    /// asked again.
    private func migrateLegacySetting() {
        let defaults = UserDefaults.standard
        if let legacy = defaults.object(forKey: "checkForUpdates") as? Bool {
            if defaults.object(forKey: "SUEnableAutomaticChecks") == nil {
                updater.automaticallyChecksForUpdates = legacy
            }
            defaults.removeObject(forKey: "checkForUpdates")
        }
        defaults.removeObject(forKey: "lastUpdateCheck")
    }
}

extension AppUpdater: SPUUpdaterDelegate {
    /// The updater starts only after onboarding, so the one-time question comes right
    /// after setup instead of on the second launch.
    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool {
        true
    }

    func updater(_ updater: SPUUpdater, willScheduleUpdateCheckAfterDelay delay: TimeInterval) {
        revision += 1
    }

    func updaterWillNotScheduleUpdateCheck(_ updater: SPUUpdater) {
        revision += 1
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        revision += 1
        #if DEBUG || UPDATE_TEST
        UpdateTest.record("cycle finished\(error.map { ": \($0.localizedDescription)" } ?? "")")
        #endif
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        log.error("Update aborted: \(error.localizedDescription, privacy: .public)")
        #if DEBUG || UPDATE_TEST
        UpdateTest.record("aborted: \(error.localizedDescription)")
        #endif
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        #if DEBUG || UPDATE_TEST
        if UpdateTest.isRequested {
            if UpdateTest.quitsToInstall {
                // Sparkle installs it as the app quits, without relaunching.
                UpdateTest.record("quitting to install \(item.displayVersionString)")
                DispatchQueue.main.async { NSApp.terminate(nil) }
                return false
            }
            UpdateTest.record("installing \(item.displayVersionString)")
            immediateInstallHandler()
            return true
        }
        #endif
        // Sparkle installs it when DockState quits.
        return false
    }

    #if DEBUG || UPDATE_TEST
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        UpdateTest.record("found \(item.displayVersionString) (\(item.versionString))")
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        UpdateTest.record("no update")
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        UpdateTest.record("downloaded \(item.displayVersionString)")
    }
    #endif
}

/// Gentle reminders: DockState lives in the menu bar, so an update found by a scheduled
/// check doesn't pop up behind other apps. It waits in the menu bar panel (and as a
/// notification) until the user looks at it.
extension AppUpdater: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        // Right after launch Sparkle can show it in front; otherwise DockState reminds.
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !handleShowingUpdate else { return }
        availableVersion = update.displayVersionString
        if !state.userInitiated { postNotification?(update.displayVersionString) }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        availableVersion = nil
        removeNotification?()
    }

    func standardUserDriverWillFinishUpdateSession() {
        availableVersion = nil
        removeNotification?()
        revision += 1
    }
}

#if DEBUG || UPDATE_TEST
/// `-DockStateUpdateTest YES -DockStateUpdateTestLog <file>` (see scripts/test-update.sh):
/// starts the updater in a development build, checks right away and installs a found
/// update immediately, writing each step to the log file. Pass the feed with
/// `-SUFeedURL <url> -SUEnableAutomaticChecks YES -SUAutomaticallyUpdate YES`.
/// `-DockStateUpdateTestQuit YES` quits instead, so Sparkle installs without relaunching.
@MainActor
enum UpdateTest {
    static var isRequested: Bool { UserDefaults.standard.bool(forKey: "DockStateUpdateTest") }
    static var quitsToInstall: Bool { UserDefaults.standard.bool(forKey: "DockStateUpdateTestQuit") }

    static func begin(_ updater: SPUUpdater) {
        record("started \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
        updater.checkForUpdatesInBackground()
    }

    static func record(_ line: String) {
        guard isRequested, let path = UserDefaults.standard.string(forKey: "DockStateUpdateTestLog") else { return }
        let url = URL(fileURLWithPath: path)
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
#endif
