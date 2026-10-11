import SwiftUI
import DockStateCore

/// Workspace management (design 1h): list on the left; displays, automation and windows
/// on the right. "Update from Current Layout" replaces re-creating a workspace.
struct ManageView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppActions.self) private var actions

    var body: some View {
        @Bindable var actions = actions
        NavigationSplitView {
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
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
            .safeAreaInset(edge: .bottom) {
                Button { actions.showSave() } label: {
                    Label(String(localized: "Save Current Layout…"), systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .disabled(!model.permissionGranted)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } detail: {
            if let id = actions.manageSelection, let ws = model.workspace(id: id) {
                WorkspaceDetail(workspace: ws)
            } else {
                ContentUnavailableView {
                    Label(String(localized: "No workspaces yet"), systemImage: "rectangle.on.rectangle")
                } description: {
                    Text("Arrange your windows, then save the layout.")
                } actions: {
                    Button(String(localized: "Save Current Layout…")) { actions.showSave() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.permissionGranted)
                }
            }
        }
        .frame(minWidth: 820, minHeight: 500)
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
        ScrollView {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 14) {
                    LayoutMapView(displays: workspace.displays, boxes: savedBoxes)
                        .frame(height: 150)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                    VStack(spacing: 0) {
                        ForEach(workspace.displays) { d in
                            HStack {
                                Text(verbatim: d.name)
                                Spacer()
                                Text(verbatim: spec(d)).foregroundStyle(.secondary)
                            }
                            .font(.system(size: 12))
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            if d.id != workspace.displays.last?.id { Divider() }
                        }
                    }
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 0.5))
                    Text(connected ? String(localized: "These displays are connected now.")
                                   : String(localized: "Not connected now. Connect these displays to restore or update."))
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("When these displays connect").font(.system(size: 12, weight: .semibold))
                        Picker("", selection: Binding(get: { workspace.autoMode }, set: { model.setAutoMode($0, for: workspace) })) {
                            ForEach(AutoMode.allCases, id: \.self) { Text(Copy.autoMode($0)).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        Text(Copy.autoModeHelp(workspace.autoMode))
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(width: 280)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(Copy.windowCount(workspace.windows.count)).font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Text("Saved \(workspace.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    WindowTable(workspace: workspace, plan: plan)
                    Text("Unchecked windows are kept in the workspace but never moved.")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            .padding(20)
        }
        .navigationTitle(workspace.name)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                TextField(String(localized: "Name"), text: $editingName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .semibold))
                    .focused($nameFocused)
                    .onSubmit { model.rename(workspace, to: editingName) }
                    .frame(minWidth: 140)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button(String(localized: "Update from Current Layout")) {
                    Task { await model.updateFromCurrentLayout(workspace) }
                }
                .disabled(!connected || !model.permissionGranted)
                .help(String(localized: "Replace the saved positions with how windows are arranged now."))
                Button(String(localized: "Restore…")) { actions.showPreview(workspace) }
                    .disabled(!model.permissionGranted || match.quality == .none)
                Button(role: .destructive) { confirmDelete = true } label: {
                    Label(String(localized: "Delete"), systemImage: "trash")
                }
                .help(String(localized: "Delete this workspace"))
            }
        }
        .onAppear { editingName = workspace.name }
        .onChange(of: workspace.id) { editingName = workspace.name }
        .onChange(of: nameFocused) { _, focused in if !focused { model.rename(workspace, to: editingName) } }
        .confirmationDialog(String(localized: "Delete “\(workspace.name)”?"), isPresented: $confirmDelete) {
            Button(String(localized: "Delete"), role: .destructive) { model.delete(workspace) }
        } message: {
            Text("Your windows won’t be affected. You can undo right after deleting.")
        }
    }

    private var savedBoxes: [MapBox] {
        workspace.windows.reversed().compactMap { w in
            guard let d = workspace.display(id: w.displayID) else { return nil }
            return MapBox(id: w.id.uuidString, frame: w.frameInDisplay.offsetBy(dx: d.frame.x, dy: d.frame.y),
                          color: AppStyle.color(for: w.bundleID).opacity(w.isExcluded ? 0.35 : 1),
                          label: w.appName, style: .solid)
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
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Window").frame(maxWidth: .infinity, alignment: .leading)
                Text("Display").frame(width: 120, alignment: .leading)
                Text("Status").frame(width: 80, alignment: .leading)
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(.leading, 34).padding(.trailing, 10).padding(.vertical, 6)
            Divider()
            ForEach(Array(workspace.windows.enumerated()), id: \.element.id) { index, w in
                HStack(spacing: 8) {
                    Toggle("", isOn: Binding(get: { !w.isExcluded }, set: { model.setExcluded(!$0, window: w, in: workspace) }))
                        .toggleStyle(.checkbox).labelsHidden()
                        .help(String(localized: "Include this window when restoring"))
                    HStack(spacing: 7) {
                        AppIconView(bundleID: w.bundleID, size: 14)
                        (Text(verbatim: w.appName) + Text(verbatim: w.title.map { "  \($0)" } ?? "").foregroundColor(.secondary))
                            .lineLimit(1).truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(verbatim: workspace.display(id: w.displayID)?.name ?? "—")
                        .foregroundStyle(.secondary).lineLimit(1)
                        .frame(width: 120, alignment: .leading)
                    status(w).frame(width: 80, alignment: .leading)
                }
                .font(.system(size: 12))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.035))
                .opacity(w.isExcluded ? 0.5 : 1)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func status(_ w: SavedWindow) -> some View {
        if w.isExcluded {
            Text("Excluded").foregroundStyle(.tertiary)
        } else if let plan, let item = plan.items.first(where: { $0.saved.id == w.id }) {
            switch item.kind {
            case .inPlace: Text("In place").foregroundStyle(.green)
            case .move: Text("Moved").foregroundStyle(.secondary)
            case .skip(let reason):
                Text(reason == .appNotRunning ? String(localized: "Not open") : String(localized: "Can’t restore"))
                    .foregroundStyle(.orange)
                    .help(Copy.reason(reason, appName: w.appName))
            }
        } else {
            Text(verbatim: "—").foregroundStyle(.tertiary)
        }
    }
}
