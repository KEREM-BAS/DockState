import SwiftUI
import DockStateCore

/// The main surface (design 1d). DockState is invisible most of the time; this popover
/// answers "does this desk match a saved workspace, and is everything in place?".
struct MenuBarPopover: View {
    @Environment(AppModel.self) private var model
    @Environment(AppActions.self) private var actions

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            StatusCard()
                .padding(.bottom, 4)

            if !model.workspaces.isEmpty {
                SectionHeader(title: String(localized: "Workspaces"))
                ForEach(model.workspaces) { ws in
                    WorkspaceRow(workspace: ws, match: model.match(for: ws))
                }
            }

            Divider().padding(.vertical, 5).padding(.horizontal, 10)
            MenuRow(title: String(localized: "Save Current Layout…"), shortcut: shortcut(.save),
                    enabled: model.permissionGranted) { actions.showSave() }
            MenuRow(title: String(localized: "Undo Last Restore"), shortcut: shortcut(.undo),
                    enabled: model.canUndo) { actions.undo() }
            Divider().padding(.vertical, 5).padding(.horizontal, 10)
            MenuRow(title: String(localized: "Manage Workspaces…")) { actions.showManage() }
            MenuRow(title: String(localized: "Settings…"), shortcut: "⌘,") { actions.showSettings() }
                .keyboardShortcut(",", modifiers: .command)
            MenuRow(title: String(localized: "Quit DockState"), shortcut: "⌘Q") { actions.quit() }
                .keyboardShortcut("q", modifiers: .command)
        }
        .padding(6)
        .frame(width: 320)
        .task { await model.refresh() }
    }

    private func shortcut(_ action: ShortcutAction) -> String? {
        actions.activeShortcut(for: action)?.display
    }
}

/// The one suggestion at the top of the popover.
private struct StatusCard: View {
    @Environment(AppModel.self) private var model
    @Environment(AppActions.self) private var actions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 9) {
                Circle().fill(state.dot).frame(width: 8, height: 8).padding(.top, 4)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.title).font(.system(size: 13, weight: .semibold))
                    Text(state.subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            switch state.kind {
            case .permission:
                Button(String(localized: "Allow…")) { actions.requirePermission(then: nil) }
                    .buttonStyle(.bordered).frame(maxWidth: .infinity)
            case .save:
                Button(String(localized: "Save Current Layout…")) { actions.showSave() }
                    .buttonStyle(.bordered).frame(maxWidth: .infinity)
            case .match(let ws):
                HStack(spacing: 6) {
                    Button { actions.showPreview(ws) } label: { Text("Preview").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered)
                    Button { actions.restore(ws) } label: { Text("Restore").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isBusy)
                }
                .controlSize(.regular)
            case .info:
                EmptyView()
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 0.5))
    }

    private enum Kind { case permission, save, match(Workspace), info }

    private var state: (dot: Color, title: String, subtitle: String, kind: Kind) {
        if !model.permissionGranted {
            return (.orange, String(localized: "DockState needs permission"),
                    String(localized: "Allow Accessibility access to save and restore."), .permission)
        }
        if model.workspaces.isEmpty {
            return (.secondary, String(localized: "No workspaces yet"),
                    String(localized: "Arrange your windows, then save them."), .save)
        }
        if let candidate = model.recognized {
            let plan = model.plan(for: candidate.workspace)
            let moves = plan.moves.count
            let apps = model.appsToOpen(for: plan).count
            if moves > 0 || apps > 0 {
                var parts: [String] = []
                if moves > 0 { parts.append(String(localized: "\(moves) windows are out of place")) }
                if apps > 0 { parts.append(String(localized: "\(apps) apps aren’t open")) }
                return (.green, String(localized: "These displays match \(candidate.workspace.name)"),
                        parts.joined(separator: " · "), .match(candidate.workspace))
            }
            return (.green, String(localized: "\(candidate.workspace.name) is in place"),
                    String(localized: "Every saved window is where you left it."), .info)
        }
        let sub = model.displays.count == 1 && model.displays[0].isBuiltin
            ? String(localized: "Built-in display only")
            : String(localized: "\(model.displays.count) displays connected")
        return (.secondary, String(localized: "This display setup isn’t saved"), sub, .save)
    }
}

private struct WorkspaceRow: View {
    @Environment(AppModel.self) private var model
    @Environment(AppActions.self) private var actions
    var workspace: Workspace
    var match: DisplayMatch
    @State private var hovering = false

    var body: some View {
        let connected = match.quality.isRecognized
        Button {
            if match.quality == .none { actions.showManage(selecting: workspace) } else { actions.showPreview(workspace) }
        } label: {
            HStack(spacing: 10) {
                DisplayGlyph(count: workspace.displays.count)
                    .opacity(connected ? 1 : 0.5)
                VStack(alignment: .leading, spacing: 1) {
                    Text(workspace.name).font(.system(size: 13))
                    Text(verbatim: "\(Copy.displayCount(workspace)) · \(Copy.connection(match))")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .opacity(connected ? 1 : 0.55)
                Spacer()
                if connected {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(.green)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(hovering ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityHint(connected ? Text("Shows what will move before restoring") : Text("Opens the workspace"))
    }
}

/// Tiny outline of one to three displays used in workspace rows.
struct DisplayGlyph: View {
    var count: Int

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            RoundedRectangle(cornerRadius: 1.5).strokeBorder(.primary, lineWidth: 1.3).frame(width: 10, height: 8)
            if count > 1 { RoundedRectangle(cornerRadius: 1.5).strokeBorder(.primary, lineWidth: 1.3).frame(width: 8, height: 7) }
            if count > 2 { RoundedRectangle(cornerRadius: 1.5).strokeBorder(.primary, lineWidth: 1.3).frame(width: 7, height: 6) }
        }
        .frame(width: 30, alignment: .leading)
        .accessibilityHidden(true)
    }
}

struct SectionHeader: View {
    var title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }
}

/// A menu-like row with native hover highlight.
struct MenuRow: View {
    var title: String
    var shortcut: String? = nil
    var enabled = true
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if let shortcut { Text(verbatim: shortcut).opacity(0.55) }
            }
            .font(.system(size: 13))
            .foregroundStyle(hovering && enabled ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(hovering && enabled ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .onHover { hovering = $0 }
    }
}
