import SwiftUI
import DockStateCore

/// Workspace management (design 1h): list on the left; displays, automation and windows
/// on the right. "Update from Current Layout" replaces re-creating a workspace.
struct ManageView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppActions.self) private var actions

    var body: some View {
        @Bindable var actions = actions
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                List(selection: $actions.manageSelection) {
                    Section(String(localized: "Workspaces")) {
                        ForEach(model.workspaces) { ws in
                            HStack {
                                Text(verbatim: ws.name)
                                Spacer()
                                if model.match(for: ws).quality.isRecognized {
                                    Text("connected").font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                            }
                            .tag(ws.id)
                            .contextMenu {
                                Button(String(localized: "Delete"), role: .destructive) { model.delete(ws) }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                HStack(spacing: 6) {
                    Button { actions.showSave() } label: {
                        Label(String(localized: "Save Current Layout…"), systemImage: "plus")
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .buttonStyle(.borderless)
                    .disabled(!model.permissionGranted)
                    .help(String(localized: "Save Current Layout…"))
                    Spacer(minLength: 0)
                    Menu {
                        Button(String(localized: "Export Workspaces…")) { actions.exportWorkspaces() }
                            .disabled(model.workspaces.isEmpty)
                        Button(String(localized: "Import Workspaces…")) { actions.importWorkspaces() }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(String(localized: "Export or import workspaces"))
                    .accessibilityLabel(Text("More"))
                }
                .padding(12)
            }
            .frame(width: 220)
            .background(.regularMaterial)

            Divider()

            Group {
                if let id = actions.manageSelection, let ws = model.workspace(id: id) {
                    WorkspaceDetail(workspace: ws).id(ws.id)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "rectangle.on.rectangle").font(.system(size: 32)).foregroundStyle(.tertiary).accessibilityHidden(true)
                        Text("No workspaces yet").font(.system(size: 13, weight: .semibold))
                        Text("Arrange your windows, then save the layout.").font(.system(size: 13)).foregroundStyle(.secondary)
                        Button(String(localized: "Save Current Layout…")) { actions.showSave() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!model.permissionGranted)
                            .padding(.top, 6)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 900, minHeight: 560)
        .background {
            // ⌘Z brings back a workspace deleted here (the toast's Undo is mouse-only).
            Button(String(localized: "Undo Delete")) { model.undoDelete() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!model.canUndoDelete)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .onChange(of: model.workspaces.map(\.id)) { _, ids in
            // After a delete (or import), keep something sensible selected.
            if let selected = actions.manageSelection, ids.contains(selected) { return }
            actions.manageSelection = ids.first
        }
    }
}

private struct WorkspaceDetail: View {
    @Environment(AppModel.self) private var model
    @Environment(AppActions.self) private var actions
    var workspace: Workspace
    @State private var confirmDelete = false
    @State private var editingName = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        let match = model.match(for: workspace)
        let connected = match.quality.isRecognized
        let plan = connected ? model.plan(for: workspace) : nil
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField(String(localized: "Name"), text: $editingName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .semibold))
                    .focused($nameFocused)
                    .onSubmit(commitRename)
                    .accessibilityLabel(Text("Workspace name"))
                Button(String(localized: "Update from Current Layout")) {
                    Task { await model.updateFromCurrentLayout(workspace) }
                }
                .disabled(!connected || !model.permissionGranted)
                .help(String(localized: "Replace the saved positions with how windows are arranged now."))
                Button(String(localized: "Restore…")) { actions.showPreview(workspace) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.permissionGranted || match.quality == .none)
                Button(String(localized: "Delete"), role: .destructive) { confirmDelete = true }
                    .help(String(localized: "Delete this workspace"))
            }
            .controlSize(.small)
            .padding(.horizontal, 16)
            .frame(height: 44)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    overview(connected: connected)
                        .padding(18)
                }
                .frame(minWidth: 240, idealWidth: 270, maxWidth: 320)
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(Copy.windowCount(workspace.windows.count)).font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Text("Saved \(workspace.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16).padding(.top, 14)
                    WindowTable(workspace: workspace, plan: plan)
                    Text("Unchecked windows are kept in the workspace but never moved.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .padding(.horizontal, 16).padding(.bottom, 12)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .layoutPriority(1)
            }
        }
        .onAppear { editingName = workspace.name }
        .onChange(of: workspace.name) { _, name in if !nameFocused { editingName = name } }
        .onChange(of: nameFocused) { _, focused in if !focused { commitRename() } }
        .confirmationDialog(String(localized: "Delete “\(workspace.name)”?"), isPresented: $confirmDelete) {
            Button(String(localized: "Delete"), role: .destructive) { model.delete(workspace) }
        } message: {
            Text("Your windows won’t be affected. You can undo right after deleting.")
        }
    }

    private func commitRename() {
        switch model.rename(workspace, to: editingName) {
        case .renamed, .unchanged: break
        case .empty: editingName = workspace.name
        case .nameTaken:
            editingName = workspace.name
            NSSound.beep()
        }
    }

    private func overview(connected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            LayoutMapView(displays: workspace.displays, boxes: savedBoxes)
                .frame(height: 140)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            VStack(spacing: 0) {
                ForEach(workspace.displays) { d in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: d.name).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                        Text(verbatim: spec(d)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .help(d.name)
                    if d.id != workspace.displays.last?.id { Divider() }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 0.5))
            Text(connected ? String(localized: "These displays are connected now.")
                           : String(localized: "Not connected now. Connect these displays to restore or update."))
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Text("When these displays connect").font(.system(size: 12, weight: .semibold))
                // A vertical radio group fits any translation, unlike a segmented control.
                Picker(String(localized: "When these displays connect"),
                       selection: Binding(get: { workspace.autoMode }, set: { model.setAutoMode($0, for: workspace) })) {
                    ForEach(AutoMode.allCases, id: \.self) { Text(Copy.autoMode($0)).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                Text(Copy.autoModeHelp(workspace.autoMode))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var savedBoxes: [MapBox] {
        workspace.windows.compactMap { w in
            guard let d = workspace.display(id: w.displayID) else { return nil }
            return MapBox(id: w.id.uuidString, frame: w.frameInDisplay.offsetBy(dx: d.frame.x, dy: d.frame.y),
                          color: AppStyle.color(for: w.bundleID), label: w.appName,
                          style: w.isExcluded ? .excluded : .solid)
        }
    }

    private func spec(_ d: DisplayDescriptor) -> String {
        var parts: [String] = []
        if d.isBuiltin { parts.append(String(localized: "Built-in")) }
        if d.isMain { parts.append(String(localized: "Main")) }
        parts.append(d.resolutionText)
        return parts.joined(separator: " · ")
    }
}

private struct WindowTable: View {
    @Environment(AppModel.self) private var model
    var workspace: Workspace
    var plan: RestorePlan?

    var body: some View {
        Table(workspace.windows) {
            TableColumn(String(localized: "Include")) { w in
                Toggle(isOn: Binding(get: { !w.isExcluded }, set: { model.setExcluded(!$0, window: w, in: workspace) })) {
                    Text(verbatim: [w.appName, w.title].compactMap { $0 }.joined(separator: " — "))
                }
                .toggleStyle(.checkbox).labelsHidden()
                .help(String(localized: "Include this window when restoring"))
            }
            .width(min: 44, ideal: 56, max: 70)
            TableColumn(String(localized: "Window")) { w in
                HStack(spacing: 7) {
                    AppIconView(bundleID: w.bundleID, size: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: w.appName).lineLimit(1)
                        if let title = w.title, !title.isEmpty {
                            Text(verbatim: title).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .opacity(w.isExcluded ? 0.5 : 1)
            }
            .width(min: 110, ideal: 160)
            TableColumn(String(localized: "Display")) { w in
                Text(verbatim: workspace.display(id: w.displayID)?.name ?? "—")
                    .foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 60, ideal: 100, max: 200)
            TableColumn(String(localized: "Status")) { w in
                status(w).lineLimit(1)
            }
            .width(min: 70, ideal: 96, max: 160)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .font(.system(size: 12))
    }

    @ViewBuilder
    private func status(_ w: SavedWindow) -> some View {
        if w.isExcluded {
            Text("Excluded").foregroundStyle(.secondary)
        } else if let plan, let item = plan.items.first(where: { $0.saved.id == w.id }) {
            switch item.kind {
            case .inPlace: Text("In place").foregroundStyle(Color(nsColor: .systemGreen))
            case .move: Text("Out of place").foregroundStyle(.primary)
            case .skip(let reason):
                Text(reason == .appNotRunning ? String(localized: "Not open") : String(localized: "Can’t restore"))
                    .foregroundStyle(Color(nsColor: .systemOrange))
                    .help(Copy.reason(reason, appName: w.appName))
            }
        } else {
            Text(verbatim: "—").foregroundStyle(.secondary)
                .help(String(localized: "Connect these displays to see the status."))
        }
    }
}
