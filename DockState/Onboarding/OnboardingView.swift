import SwiftUI
import DockStateCore
import DockStateSystem

/// First run (design 1a–1c): promise, permission, first workspace.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppActions.self) private var actions

    var body: some View {
        Group {
            switch actions.onboardingStep {
            case .welcome: WelcomeStep()
            case .permission: PermissionStep()
            case .firstSave: FirstSaveStep()
            }
        }
        .padding(.top, 28)
        .frame(width: 640)
        .animation(.easeInOut(duration: 0.2), value: actions.onboardingStep)
    }
}

private struct StepDots: View {
    var current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3) { i in
                Circle().fill(i == current ? Color.primary : Color.primary.opacity(0.15)).frame(width: 7, height: 7)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Step \(current + 1) of 3"))
    }
}

private struct WelcomeStep: View {
    @Environment(AppModel.self) private var model
    @Environment(AppActions.self) private var actions

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                DockStateMark(size: 64)
                Text("Your workspace, right where you left it.")
                    .font(.system(size: 22, weight: .bold))
                    .multilineTextAlignment(.center)
                Text("DockState remembers where your windows sit for each display setup. When you plug your displays back in, it puts everything back — only when you say so.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 48)

            HStack(spacing: 10) {
                StepCard(number: 1, title: String(localized: "Save"),
                         text: String(localized: "Arrange your windows once and save them as a workspace."))
                StepCard(number: 2, title: String(localized: "Reconnect"),
                         text: String(localized: "Plug in your displays. DockState recognizes the setup."))
                StepCard(number: 3, title: String(localized: "Restore"),
                         text: String(localized: "See what will move, then restore in one click. Undo anytime."))
            }
            .padding(.horizontal, 32)
            .padding(.top, 22)

            HStack {
                StepDots(current: 0)
                Spacer()
                Button(String(localized: "Get Started")) {
                    actions.onboardingStep = model.permissionGranted ? .firstSave : .permission
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(24)
        }
    }
}

private struct StepCard: View {
    var number: Int
    var title: String
    var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: "\(number)")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 22, height: 22)
                .background(Color.accentColor.opacity(0.14), in: Circle())
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(text).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 120, maxHeight: 140, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5))
    }
}

private struct PermissionStep: View {
    @Environment(AppModel.self) private var model
    @Environment(AppActions.self) private var actions
    @State private var waiting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Allow DockState to arrange your windows")
                    .font(.system(size: 20, weight: .bold))
                Text("macOS asks you to approve any app that moves other apps’ windows. DockState uses this permission only to read and set window positions and sizes.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 40)

            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("DockState can").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                    Label(String(localized: "See which windows are open and where"), systemImage: "checkmark")
                    Label(String(localized: "Move and resize them when you restore"), systemImage: "checkmark")
                }
                .labelStyle(PermissionLabelStyle(color: .green))
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("DockState never").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                    Label(String(localized: "Reads what’s inside your windows"), systemImage: "minus")
                    Label(String(localized: "Records your screen or keystrokes"), systemImage: "minus")
                    Label(String(localized: "Sends anything off your Mac"), systemImage: "minus")
                }
                .labelStyle(PermissionLabelStyle(color: .secondary))
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5))
            .padding(.horizontal, 40)
            .padding(.top, 18)

            HStack(spacing: 12) {
                Text("In System Settings, go to **Privacy & Security › Accessibility** and turn on DockState.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: model.permissionGranted ? "checkmark.circle.fill" : "switch.2")
                    .foregroundStyle(model.permissionGranted ? Color.green : Color.secondary)
                    .font(.system(size: 16))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 40)
            .padding(.top, 12)

            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Circle().fill(statusColor).frame(width: 8, height: 8)
                    Text(statusText).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(String(localized: "Not Now")) { actions.finishOnboarding() }
                Button(String(localized: "Open System Settings")) {
                    waiting = true
                    model.requestPermission()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(model.permissionGranted)
            }
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.top, 22)

            HStack(spacing: 4) {
                Text("DockState is open source.")
                Link(String(localized: "Read the code on GitHub"), destination: Links.repository)
            }
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 24)
            .padding(.top, 14)
            .padding(.bottom, 18)
        }
        .onAppear { model.beginWatchingPermission() }
        .onChange(of: model.permissionGranted) { _, granted in
            guard granted else { return }
            Task {
                // Let the user see the confirmation before moving on — no click needed.
                try? await Task.sleep(for: .milliseconds(900))
                await model.refresh()
                actions.onboardingStep = .firstSave
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    private var statusText: String {
        if model.permissionGranted { return String(localized: "Permission granted — continuing…") }
        if waiting { return String(localized: "Waiting for permission — this updates on its own.") }
        return String(localized: "Not allowed yet")
    }

    private var statusColor: Color {
        model.permissionGranted ? .green : waiting ? .orange : .secondary
    }
}

private struct PermissionLabelStyle: LabelStyle {
    var color: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.icon.font(.system(size: 11, weight: .bold)).foregroundStyle(color).frame(width: 12)
            configuration.title.font(.system(size: 12.5))
        }
    }
}

private struct FirstSaveStep: View {
    @Environment(AppModel.self) private var model
    @Environment(AppActions.self) private var actions
    @State private var name = ""
    @State private var excluded: Set<LiveWindowID> = []

    var body: some View {
        let windows = model.capturableWindows
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Save your first workspace").font(.system(size: 20, weight: .bold))
                Text("This is how your windows are arranged right now.").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 32)

            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    LayoutMapView(displays: model.displays, boxes: MapBoxes.current(windows.filter { !excluded.contains($0.id) }))
                        .frame(width: 250, height: 150)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                    Text("\(model.displays.count) displays recognized: \(Copy.displayList(model.displays))")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                        .frame(width: 250, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Name").font(.system(size: 12, weight: .semibold))
                        TextField(String(localized: "Workspace name"), text: $name)
                            .textFieldStyle(.roundedBorder)
                        HStack(spacing: 6) {
                            ForEach(nameChips, id: \.self) { chip in
                                Button(chip) { name = chip }
                                    .buttonStyle(ChipStyle(selected: name == chip))
                            }
                        }
                    }
                    WindowChecklist(windows: windows, displays: model.displays, excluded: $excluded)
                        .frame(height: 170)
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 18)

            HStack {
                StepDots(current: 2)
                Text("You can rename or update it anytime.").font(.system(size: 11.5)).foregroundStyle(.tertiary)
                    .padding(.leading, 8)
                Spacer()
                Button(String(localized: "Skip")) { actions.finishOnboarding() }
                Button(String(localized: "Save Workspace")) {
                    if let ws = model.saveCurrentLayout(named: name, excluding: excluded) {
                        actions.finishOnboarding()
                        model.presenter?.toast(String(localized: "Saved “\(ws.name)”"))
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || windows.count == excluded.count)
            }
            .controlSize(.large)
            .padding(24)
        }
        .task {
            await model.refresh()
            if name.isEmpty { name = model.suggestedName() }
        }
    }

    private var nameChips: [String] {
        [String(localized: "Home Desk"), String(localized: "Office"), String(localized: "Laptop Only")]
    }
}

struct ChipStyle: ButtonStyle {
    var selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            .background(selected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.08), in: Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Windows that will be saved, each with a checkbox (design 1c).
struct WindowChecklist: View {
    var windows: [LiveWindow]
    var displays: [DisplayDescriptor]
    @Binding var excluded: Set<LiveWindowID>

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(windows.count - excluded.count) of \(windows.count) windows")
                Spacer()
                Text("Display")
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.vertical, 6)
            Divider()
            if windows.isEmpty {
                Text("No windows found on this Space.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(windows) { w in
                            Toggle(isOn: Binding(
                                get: { !excluded.contains(w.id) },
                                set: { on in if on { excluded.remove(w.id) } else { excluded.insert(w.id) } })
                            ) {
                                HStack(spacing: 8) {
                                    AppIconView(bundleID: w.bundleID, size: 16)
                                    (Text(verbatim: w.appName) + Text(verbatim: w.title.map { "  \($0)" } ?? "").foregroundColor(.secondary))
                                        .lineLimit(1).truncationMode(.tail)
                                    Spacer()
                                    Text(verbatim: displays.display(containing: w.frame)?.name ?? "")
                                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                }
                                .font(.system(size: 12))
                            }
                            .toggleStyle(.checkbox)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 0.5))
    }
}

enum MapBoxes {
    static func current(_ windows: [LiveWindow]) -> [MapBox] {
        windows.reversed().map {
            MapBox(id: $0.id.description, frame: $0.frame, color: AppStyle.color(for: $0.bundleID), label: $0.appName, style: .solid)
        }
    }
}

enum Links {
    static let repository = URL(string: "https://github.com/KEREM-BAS/DockState")!
    static let issues = URL(string: "https://github.com/KEREM-BAS/DockState/issues")!
}
