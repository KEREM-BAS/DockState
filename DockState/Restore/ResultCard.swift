import SwiftUI
import DockStateCore
import DockStateSystem

/// After a restore (design 1g): success first, then what's missing — each with a reason
/// and, when possible, a one-click fix. Undo stays one click away.
struct ResultCard: View {
    @Environment(AppModel.self) private var model
    @Environment(AppActions.self) private var actions
    var onClose: () -> Void

    var body: some View {
        if let result = model.lastResult {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20)).foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(result.workspaceName) restored").font(.system(size: 13.5, weight: .semibold))
                        Text(subtitle(result)).font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if result.automatic {
                            Text("Restored automatically · Always restore is on")
                                .font(.system(size: 11)).foregroundStyle(.tertiary)
                        }
                    }
                }
                if !result.notRestored.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(result.notRestored.prefix(5).enumerated()), id: \.offset) { _, failure in
                            HStack(spacing: 9) {
                                AppIconView(bundleID: failure.saved.bundleID, size: 16)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(verbatim: failure.saved.appName).font(.system(size: 12))
                                    Text(Copy.reason(failure.reason, appName: failure.saved.appName))
                                        .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                                }
                                Spacer()
                                if model.canOpenAndPlace(failure.saved, reason: failure.reason),
                                   let ws = model.workspace(id: result.workspaceID) {
                                    Button(String(localized: "Open & Place")) {
                                        Task { await model.openAndPlace(bundleID: failure.saved.bundleID, workspace: ws) }
                                    }
                                    .buttonStyle(PanelButtonStyle())
                                    .fixedSize()
                                    .disabled(model.isBusy)
                                }
                            }
                            .padding(.horizontal, 10).padding(.vertical, 7)
                        }
                        if result.notRestored.count > 5 {
                            Text("and \(result.notRestored.count - 5) more")
                                .font(.system(size: 11)).foregroundStyle(.secondary).padding(.bottom, 6)
                        }
                    }
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 0.5))
                }
                HStack(spacing: 6) {
                    Button { actions.undo() } label: { Text("Undo").frame(maxWidth: .infinity) }
                        .buttonStyle(PanelButtonStyle())
                        .disabled(!model.canUndoLastResult || model.isBusy)
                    Button { onClose() } label: { Text("Done").frame(maxWidth: .infinity) }
                        .buttonStyle(AccentButtonStyle())
                }
            }
            .padding(16)
            .frame(width: 340)
            .card()
        }
    }

    private func subtitle(_ r: RestoreResult) -> String {
        if r.movedCount == 0 && r.notRestored.isEmpty { return String(localized: "Everything was already in place.") }
        if r.notRestored.isEmpty { return String(localized: "\(r.movedCount) windows are back in place.") }
        return String(localized: "\(r.movedCount) windows moved.") + " " + String(localized: "\(r.notRestored.count) couldn’t be restored.")
    }
}

/// The small capsule at the bottom of the screen confirming an action.
struct ToastView: View {
    var message: String
    var actionTitle: String?
    var action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(verbatim: message).font(.system(size: 12.5))
            if let actionTitle {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
        .padding(1)
    }
}
