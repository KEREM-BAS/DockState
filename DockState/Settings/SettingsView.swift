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
        .frame(width: 520, height: 360)
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
                        Text(subtitle).font(.system(size: 11)).foregroundStyle(.tertiary)
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
                SettingsRow(title: String(localized: "Open at login")) {
                    Toggle("", isOn: Binding(get: { loginEnabled }, set: { actions.opensAtLogin = $0; loginEnabled = actions.opensAtLogin }))
                        .toggleStyle(.switch).labelsHidden().controlSize(.small)
                }
                SettingsRow(title: String(localized: "Notify when known displays connect"),
                            subtitle: String(localized: "Workspaces set to “Always restore” skip this."), showsDivider: false) {
                    Toggle("", isOn: $settings.notifyOnConnect).toggleStyle(.switch).labelsHidden().controlSize(.small)
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
                SettingsRow(title: String(localized: "If an app isn’t open")) {
                    Picker("", selection: $settings.appNotRunningPolicy) {
                        Text("Skip it").tag(AppNotRunningPolicy.skip)
                        Text("Open it first").tag(AppNotRunningPolicy.openFirst)
                    }
                    .labelsHidden().fixedSize()
                }
                SettingsRow(title: String(localized: "If a saved display is missing")) {
                    Picker("", selection: $settings.missingDisplayPolicy) {
                        Text("Use main display").tag(MissingDisplayPolicy.useMainDisplay)
                        Text("Leave windows in place").tag(MissingDisplayPolicy.leaveInPlace)
                    }
                    .labelsHidden().fixedSize()
                }
                SettingsRow(title: String(localized: "Use window titles to tell windows apart"),
                            subtitle: String(localized: "Helps with apps that have several windows. Titles are stored only on this Mac and never logged."),
                            showsDivider: false) {
                    Toggle("", isOn: Binding(
                        get: { settings.useWindowTitles },
                        set: { on in
                            settings.useWindowTitles = on
                            if !on { model.purgeTitles() }
                        })
                    ).toggleStyle(.switch).labelsHidden().controlSize(.small)
                }
            }
            Text("Each workspace can ask, restore automatically, or do nothing when its displays connect. Change this in Manage Workspaces.")
                .font(.system(size: 11.5)).foregroundStyle(.tertiary)
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
                    Toggle("", isOn: Binding(get: { settings.globalShortcutsEnabled },
                                             set: { settings.globalShortcutsEnabled = $0; actions.installHotKeys() }))
                        .toggleStyle(.switch).labelsHidden().controlSize(.small)
                }
            }
            SettingsGroup {
                shortcut(String(localized: "Save current layout"), "⌥⌘S")
                shortcut(String(localized: "Restore matching workspace"), "⌥⌘R")
                shortcut(String(localized: "Undo last restore"), "⌥⌘Z", divider: false)
            }
            .opacity(settings.globalShortcutsEnabled ? 1 : 0.45)
        }
    }

    private func shortcut(_ title: String, _ keys: String, divider: Bool = true) -> some View {
        SettingsRow(title: title, showsDivider: divider) {
            Text(verbatim: keys).font(.system(size: 12))
                .padding(.horizontal, 8).padding(.vertical, 1)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
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
            }
            .font(.system(size: 12))
            Button(copied ? String(localized: "Copied") : String(localized: "Copy Diagnostics")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(Diagnostics.report(model: model), forType: .string)
                copied = true
            }
            .padding(.top, 8)
            Text("Includes versions and display models — never window titles or app names.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
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
            Picker("", selection: $selection) {
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
