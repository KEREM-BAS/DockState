import SwiftUI
import DockStateCore
import DockStateSystem

/// Settings (design 1i): four small decisions; everything else has a sensible default.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppActions.self) private var actions

    var body: some View {
        @Bindable var actions = actions
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(SettingsTab.allCases) { tab in
                    TabButton(tab: tab, selected: actions.settingsTab == tab) { actions.settingsTab = tab }
                }
            }
            .padding(.vertical, 6)
            Divider()
            Group {
                switch actions.settingsTab {
                case .general: GeneralSettings()
                case .restore: RestoreSettings()
                case .shortcuts: ShortcutSettings()
                case .about: AboutSettings()
                }
            }
            .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 22)
            .frame(maxWidth: .infinity, alignment: .top)
            Spacer(minLength: 0)
        }
        .frame(width: 520)
        .frame(minHeight: 300)
        .environment(\.openURL, OpenURLAction { url in
            actions.openExternal(url)
            return .handled
        })
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct TabButton: View {
    var tab: SettingsTab
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 17)).frame(height: 20)
                Text(title).font(.system(size: 11))
            }
            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(selected ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var title: String {
        switch tab {
        case .general: String(localized: "General")
        case .restore: String(localized: "Restore")
        case .shortcuts: String(localized: "Shortcuts")
        case .about: String(localized: "About")
        }
    }

    private var icon: String {
        switch tab {
        case .general: "gearshape"
        case .restore: "arrow.uturn.backward.square"
        case .shortcuts: "command"
        case .about: "info.circle"
        }
    }
}

/// A grouped box of rows, like System Settings.
struct SettingsGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 0.5))
    }
}

struct SettingsRow<Trailing: View>: View {
    var title: String
    var subtitle: String? = nil
    var showsDivider = true
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13))
                    if let subtitle {
                        Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                trailing
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            if showsDivider { Divider().padding(.leading, 12) }
        }
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(AppActions.self) private var actions
    @State private var loginEnabled = false

    var body: some View {
        @Bindable var settings = model.settings
        VStack(spacing: 14) {
            SettingsGroup {
                LanguageRow()
                SettingsRow(title: String(localized: "Keep DockState windows on top"),
                            subtitle: String(localized: "DockState’s windows stay above other apps’ windows. Links open in front of them.")) {
                    Toggle(String(localized: "Keep DockState windows on top"), isOn: Binding(
                        get: { settings.keepWindowsOnTop },
                        set: { settings.keepWindowsOnTop = $0; actions.applyWindowLevels() }))
                        .toggleStyle(.switch).labelsHidden().controlSize(.small)
                }
                SettingsRow(title: String(localized: "Open at login")) {
                    Toggle(String(localized: "Open at login"), isOn: Binding(get: { loginEnabled }, set: { actions.opensAtLogin = $0; loginEnabled = actions.opensAtLogin }))
                        .toggleStyle(.switch).labelsHidden().controlSize(.small)
                }
                SettingsRow(title: String(localized: "Notify when known displays connect"),
                            subtitle: String(localized: "Workspaces set to “Always restore” skip this."), showsDivider: false) {
                    Toggle(String(localized: "Notify when known displays connect"), isOn: $settings.notifyOnConnect).toggleStyle(.switch).labelsHidden().controlSize(.small)
                }
            }
            SettingsGroup {
                SettingsRow(title: String(localized: "Check for updates automatically"),
                            subtitle: String(localized: "Once a day, DockState checks GitHub for a new version. Nothing about you is sent.")) {
                    Toggle(String(localized: "Check for updates automatically"), isOn: Binding(
                        get: { updater.automaticallyChecks }, set: { updater.automaticallyChecks = $0 }))
                        .toggleStyle(.switch).labelsHidden().controlSize(.small)
                }
                SettingsRow(title: String(localized: "Download and install updates automatically"),
                            subtitle: String(localized: "Installs when you quit DockState or restart your Mac.")) {
                    Toggle(String(localized: "Download and install updates automatically"), isOn: Binding(
                        get: { updater.automaticallyDownloads }, set: { updater.automaticallyDownloads = $0 }))
                        .toggleStyle(.switch).labelsHidden().controlSize(.small)
                        .disabled(!updater.automaticallyChecks)
                }
                SettingsRow(title: updateStatus, showsDivider: false) {
                    Button(String(localized: "Check Now")) { updater.checkNow() }
                        .disabled(!updater.canCheck)
                }
            }
            SettingsGroup {
                SettingsRow(title: String(localized: "Accessibility"),
                            subtitle: String(localized: "Needed to move and resize windows"), showsDivider: false) {
                    if model.permissionGranted {
                        Label(String(localized: "Allowed"), systemImage: "circle.fill")
                            .labelStyle(StatusLabelStyle(color: .green))
                    } else {
                        Button(String(localized: "Fix…")) { actions.requirePermission(then: nil) }
                    }
                }
            }
        }
        .onAppear { loginEnabled = actions.opensAtLogin }
    }

    private var updater: AppUpdater { actions.updater }

    private var updateStatus: String {
        if let version = updater.availableVersion { return String(localized: "DockState \(version) is available") }
        if let last = updater.lastCheck {
            return String(localized: "Last checked \(last.formatted(.relative(presentation: .named)))")
        }
        return String(localized: "Updates")
    }
}

struct StatusLabelStyle: LabelStyle {
    var color: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.system(size: 7)).foregroundStyle(color)
            configuration.title.font(.system(size: 12, weight: .medium)).foregroundStyle(color)
        }
    }
}

private struct RestoreSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        VStack(alignment: .leading, spacing: 14) {
            SettingsGroup {
                SettingsRow(title: String(localized: "If an app isn’t open"),
                            subtitle: String(localized: "Applies when you restore. Automatic restores never open apps.")) {
                    Picker(String(localized: "If an app isn’t open"), selection: $settings.appNotRunningPolicy) {
                        Text("Open it").tag(AppNotRunningPolicy.openFirst)
                        Text("Skip it").tag(AppNotRunningPolicy.skip)
                    }
                    .labelsHidden().fixedSize()
                }
                SettingsRow(title: String(localized: "If a saved display is missing")) {
                    Picker(String(localized: "If a saved display is missing"), selection: $settings.missingDisplayPolicy) {
                        Text("Use main display").tag(MissingDisplayPolicy.useMainDisplay)
                        Text("Leave windows in place").tag(MissingDisplayPolicy.leaveInPlace)
                    }
                    .labelsHidden().fixedSize()
                }
                SettingsRow(title: String(localized: "Place apps you open later"),
                            subtitle: String(localized: "After you restore a workspace, apps you open move to their saved place. Also for workspaces set to “Always restore”.")) {
                    Toggle(String(localized: "Place apps you open later"), isOn: $settings.placeLateApps)
                        .toggleStyle(.switch).labelsHidden().controlSize(.small)
                }
                SettingsRow(title: String(localized: "Use window titles to tell windows apart"),
                            subtitle: String(localized: "Helps with apps that have several windows. Titles are stored only on this Mac and never logged."),
                            showsDivider: false) {
                    Toggle(String(localized: "Use window titles to tell windows apart"), isOn: Binding(
                        get: { settings.useWindowTitles },
                        set: { on in
                            settings.useWindowTitles = on
                            if !on { model.purgeTitles() }
                        })
                    ).toggleStyle(.switch).labelsHidden().controlSize(.small)
                }
            }
            Text("Each workspace can ask, restore automatically, or do nothing when its displays connect. Change this in Manage Workspaces.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ShortcutSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(AppActions.self) private var actions

    var body: some View {
        @Bindable var settings = model.settings
        VStack(alignment: .leading, spacing: 14) {
            SettingsGroup {
                SettingsRow(title: String(localized: "Use global keyboard shortcuts"),
                            subtitle: String(localized: "They work in every app and take priority over the app’s own shortcut."),
                            showsDivider: false) {
                    Toggle(String(localized: "Use global keyboard shortcuts"), isOn: Binding(
                        get: { settings.globalShortcutsEnabled },
                        set: { settings.globalShortcutsEnabled = $0; actions.installHotKeys() }))
                        .toggleStyle(.switch).labelsHidden().controlSize(.small)
                }
            }
            SettingsGroup {
                ForEach(Array(ShortcutAction.allCases.enumerated()), id: \.element) { index, action in
                    SettingsRow(title: action.title, subtitle: subtitle(for: action),
                                showsDivider: index < ShortcutAction.allCases.count - 1) {
                        ShortcutRecorder(action: action)
                    }
                }
            }
            .disabled(!settings.globalShortcutsEnabled)
            .opacity(settings.globalShortcutsEnabled ? 1 : 0.45)
        }
        .onDisappear { actions.stopRecording() }
        .onChange(of: settings.globalShortcutsEnabled) { _, _ in actions.stopRecording() }
    }

    private func subtitle(for action: ShortcutAction) -> String? {
        if actions.recordingAction == action, let problem = actions.recordingProblem { return problem }
        if actions.shortcutConflicts.contains(action) {
            return String(localized: "macOS didn’t accept this shortcut. Choose another one.")
        }
        return nil
    }
}

/// Click, then press the new key combination. Esc cancels, Delete removes the shortcut.
struct ShortcutRecorder: View {
    @Environment(AppModel.self) private var model
    @Environment(AppActions.self) private var actions
    var action: ShortcutAction

    var body: some View {
        let recording = actions.recordingAction == action
        let combo = model.settings.shortcuts[action]
        let conflict = actions.shortcutConflicts.contains(action)
        HStack(spacing: 4) {
            Button {
                recording ? actions.stopRecording() : actions.startRecording(action)
            } label: {
                Text(recording ? String(localized: "Type shortcut…") : (combo?.display ?? String(localized: "Record Shortcut")))
                    .font(.system(size: 12))
                    .foregroundStyle(recording ? Color.accentColor : (conflict ? Color(nsColor: .systemOrange) : .primary))
                    .frame(minWidth: 96)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel(Text(action.title))
            .accessibilityValue(Text(recording ? String(localized: "Type shortcut…") : (combo?.display ?? String(localized: "None"))))
            .accessibilityHint(Text("Press to record a new shortcut"))
            if combo != nil && !recording {
                Button { model.settings.shortcuts[action] = nil; actions.installHotKeys() } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(String(localized: "Remove shortcut"))
                .accessibilityLabel(Text("Remove shortcut for \(action.title)"))
            }
        }
    }
}

private struct AboutSettings: View {
    @Environment(AppModel.self) private var model
    @State private var copied = false

    var body: some View {
        VStack(spacing: 8) {
            DockStateMark(size: 48)
            Text(verbatim: "DockState \(Diagnostics.version)").font(.system(size: 14, weight: .semibold))
            Text("Free and open source · MIT License").font(.system(size: 12)).foregroundStyle(.secondary)
            HStack(spacing: 14) {
                Link(String(localized: "View on GitHub"), destination: Links.repository)
                Link(String(localized: "Report an Issue"), destination: Links.issues)
                if let acknowledgements = Links.acknowledgements {
                    Link(String(localized: "Acknowledgements"), destination: acknowledgements)
                }
            }
            .font(.system(size: 12))
            Button(copied ? String(localized: "Copied") : String(localized: "Copy Diagnostics")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(Diagnostics.report(model: model), forType: .string)
                copied = true
            }
            .padding(.top, 8)
            Text("Includes versions and display models — never window titles or app names.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }
}

/// Information for bug reports. Deliberately excludes window titles, app names and serials.
@MainActor
enum Diagnostics {
    static var version: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    static func report(model: AppModel) -> String {
        var lines: [String] = []
        lines.append("DockState \(version)")
        lines.append("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        #if arch(arm64)
        lines.append("Architecture: arm64")
        #else
        lines.append("Architecture: x86_64")
        #endif
        lines.append("Accessibility: \(model.permissionGranted ? "granted" : "not granted")")
        lines.append("Displays: \(model.displays.count)")
        for d in model.displays {
            lines.append(String(format: "  - builtin=%@ main=%@ vendor=0x%X model=0x%X serial=%@ %@ px=%dx%d scale=%.1f origin=(%.0f,%.0f)",
                                d.isBuiltin.description, d.isMain.description, d.vendorID, d.modelID,
                                d.serialNumber == 0 ? "none" : "present", d.resolutionText,
                                d.pixelWidth, d.pixelHeight, d.scale, d.frame.x, d.frame.y))
        }
        lines.append("Workspaces: \(model.workspaces.count)")
        for (i, ws) in model.workspaces.enumerated() {
            let m = model.match(for: ws)
            lines.append("  - #\(i + 1): displays=\(ws.displays.count) windows=\(ws.windows.count) excluded=\(ws.windows.filter(\.isExcluded).count) mode=\(ws.autoMode.rawValue) match=\(m.quality) ambiguous=\(m.isAmbiguous)")
        }
        lines.append("Visible windows: \(model.capturableWindows.count) of \(model.liveWindows.count)")
        lines.append("Settings: titles=\(model.settings.useWindowTitles) missingDisplay=\(model.settings.missingDisplayPolicy.rawValue) appNotRunning=\(model.settings.appNotRunningPolicy.rawValue)")
        if let r = model.lastResult {
            let reasons = Dictionary(grouping: r.notRestored, by: \.reason).map { "\($0.key.rawValue)=\($0.value.count)" }.sorted()
            lines.append("Last restore: moved=\(r.movedCount) inPlace=\(r.alreadyInPlaceCount) notRestored=[\(reasons.joined(separator: ", "))]")
        }
        return lines.joined(separator: "\n")
    }
}

/// Per-app language. macOS reads `AppleLanguages` from the app's defaults at launch,
/// so a change needs a relaunch.
private struct LanguageRow: View {
    @State private var selection = AppLanguage.current
    @State private var askRestart = false

    var body: some View {
        SettingsRow(title: String(localized: "Language")) {
            Picker(String(localized: "Language"), selection: $selection) {
                Text("System (\(AppLanguage.systemLanguageName))").tag(AppLanguage.system)
                ForEach(AppLanguage.supported, id: \.self) { lang in
                    Text(verbatim: lang.nativeName).tag(lang)
                }
            }
            .labelsHidden().fixedSize()
            .onChange(of: selection) { _, new in
                guard new != AppLanguage.current else { return }
                new.apply()
                askRestart = true
            }
        }
        .alert(String(localized: "Restart DockState to change the language?"), isPresented: $askRestart) {
            Button(String(localized: "Restart")) { AppLanguage.relaunch() }
            Button(String(localized: "Later"), role: .cancel) {}
        } message: {
            Text("DockState will quit and open again in the selected language.")
        }
    }
}

enum AppLanguage: Hashable {
    case system
    case code(String)

    /// Languages with a complete translation. Add a code here after adding it to Localizable.xcstrings.
    static let supported: [AppLanguage] = [.code("en"), .code("tr")]

    static var current: AppLanguage {
        guard let list = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] as? [String],
              let first = list.first else { return .system }
        return supported.first { if case .code(let c) = $0 { first.hasPrefix(c) } else { false } } ?? .system
    }

    static var systemLanguageName: String {
        let preferred = Bundle.preferredLocalizations(from: Bundle.main.localizations, forPreferences: Locale.preferredLanguages).first ?? "en"
        return Locale(identifier: preferred).localizedString(forLanguageCode: preferred)?.capitalized ?? preferred
    }

    var nativeName: String {
        guard case .code(let c) = self else { return "" }
        return Locale(identifier: c).localizedString(forLanguageCode: c)?.capitalized(with: Locale(identifier: c)) ?? c
    }

    func apply() {
        switch self {
        case .system: UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        case .code(let c): UserDefaults.standard.set([c], forKey: "AppleLanguages")
        }
    }

    @MainActor
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.7; /usr/bin/open \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }
}
