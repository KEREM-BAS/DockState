import SwiftUI
import DockStateCore
import DockStateSystem

/// Restore preview (design 1f): a Now/After map plus exact lists of what will move,
/// what is already in place and what can't be restored — so nothing is a surprise.
struct RestorePreviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppActions.self) private var actions
    @State private var showAfter = true

    var body: some View {
        if let id = actions.previewWorkspaceID, let workspace = model.workspace(id: id) {
            content(workspace: workspace, plan: model.plan(for: workspace))
        } else {
            Text("This workspace no longer exists.").frame(width: 860, height: 470)
        }
    }

    private func content(workspace: Workspace, plan: RestorePlan) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label { Text(displayStatus(plan)) } icon: {
                            Image(systemName: plan.displayMatch.quality.isRecognized ? "checkmark" : "exclamationmark.triangle")
                                .foregroundStyle(plan.displayMatch.quality.isRecognized ? Color.green : Color.orange)
                        }
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer()
                        Picker("", selection: $showAfter) {
                            Text("Now").tag(false)
                            Text("After").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                    LayoutMapView(displays: model.displays, boxes: boxes(plan))
                        .frame(maxWidth: .infinity, minHeight: 260)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: showAfter)
                    HStack(spacing: 16) {
                        legend(solid: true, text: showAfter ? String(localized: "Where it goes") : String(localized: "Where it is now"))
                        if showAfter { legend(solid: false, text: String(localized: "Where it is now / can’t restore")) }
                    }
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20).padding(.vertical, 16)
                .frame(maxWidth: .infinity)

                Divider()

                PlanList(plan: plan, workspace: workspace)
                    .frame(width: 320)
                    .background(Color(nsColor: .controlBackgroundColor))
            }
            Divider()
            HStack(spacing: 16) {
                Toggle(isOn: Binding(
                    get: { workspace.autoMode == .always },
                    set: { model.setAutoMode($0 ? .always : .ask, for: workspace) })
                ) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Always restore \(workspace.name) when these displays connect").font(.system(size: 12.5))
                        Text("You can undo any restore.").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(!plan.displayMatch.quality.isRecognized)
                Spacer()
                Button(String(localized: "Cancel")) { actions.closePreview() }
                    .keyboardShortcut(.cancelAction)
                Button(restoreLabel(plan.moves.count)) { actions.restore(workspace) }
                    .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                    .disabled(plan.moves.isEmpty || model.isBusy)
            }
            .controlSize(.large)
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 860)
    }

    private func displayStatus(_ plan: RestorePlan) -> String {
        let total = plan.workspace.displays.count
        switch plan.displayMatch.quality {
        case .exact, .sameDisplays:
            return total == 1 ? String(localized: "The saved display is connected")
                              : String(localized: "All \(total) saved displays are connected")
        case .withExtraDisplays:
            return String(localized: "All saved displays are connected, plus \(plan.displayMatch.extra.count) other")
        case .partial, .none:
            let connected = plan.displayMatch.mapping.count
            return String(localized: "\(connected) of \(total) saved displays connected")
        }
    }

    private func restoreLabel(_ n: Int) -> String {
        n == 0 ? String(localized: "Nothing to Restore") : String(localized: "Restore \(n) Windows")
    }

    private func legend(solid: Bool, text: String) -> some View {
        HStack(spacing: 6) {
            if solid {
                RoundedRectangle(cornerRadius: 2).fill(Color.accentColor).frame(width: 14, height: 9)
            } else {
                RoundedRectangle(cornerRadius: 2).strokeBorder(Color.secondary, style: StrokeStyle(lineWidth: 1.2, dash: [2, 1.5]))
                    .frame(width: 14, height: 9)
            }
            Text(text)
        }
    }

    private func boxes(_ plan: RestorePlan) -> [MapBox] {
        guard showAfter else { return MapBoxes.current(model.liveWindows.filter { $0.isStandard && !$0.isMinimized }) }
        var result: [MapBox] = []
        for item in plan.moves {
            guard case .move(let w, let target, _) = item.kind else { continue }
            result.append(MapBox(id: "o-\(w.id)", frame: w.frame, color: .clear, label: "", style: .origin))
            result.append(MapBox(id: w.id.description, frame: target, color: AppStyle.color(for: w.bundleID), label: w.appName, style: .solid))
        }
        for item in plan.inPlace {
            guard let w = item.liveWindow else { continue }
            result.append(MapBox(id: w.id.description, frame: w.frame, color: AppStyle.color(for: w.bundleID), label: w.appName, style: .solid))
        }
        for item in plan.skipped {
            guard let display = plan.displayMatch.mapping[item.saved.displayID] else { continue }
            let frame = item.saved.frameInDisplay.offsetBy(dx: display.frame.x, dy: display.frame.y)
            result.append(MapBox(id: "s-\(item.saved.id)", frame: frame, color: .clear,
                                 label: String(localized: "\(item.saved.appName) · not restored"), style: .missing))
        }
        return result
    }
}

private struct PlanList: View {
    @Environment(AppModel.self) private var model
    var plan: RestorePlan
    var workspace: Workspace

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header(plan.moves.isEmpty ? String(localized: "Nothing to move") : String(localized: "Will move · \(plan.moves.count)"))
                ForEach(plan.moves) { item in
                    row(item.saved, detail: item.liveWindow?.title ?? item.saved.title,
                        trailing: "→ \(destination(item))")
                }
                if !plan.inPlace.isEmpty {
                    header(String(localized: "Already in place · \(plan.inPlace.count)"))
                    Text(verbatim: ListFormatter.localizedString(byJoining: plan.inPlace.map(\.saved.appName)))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .padding(.horizontal, 16).padding(.vertical, 2)
                }
                if !plan.skipped.isEmpty {
                    header(String(localized: "Won’t restore · \(plan.skipped.count)"), color: .orange)
                    ForEach(plan.skipped) { item in
                        HStack(spacing: 9) {
                            AppIconView(bundleID: item.saved.bundleID, size: 16).opacity(0.5)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(verbatim: item.saved.appName).font(.system(size: 12))
                                Text(Copy.reason(item.skipReason!, appName: item.saved.appName))
                                    .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                            }
                            Spacer()
                            if model.canOpenAndPlace(item.saved, reason: item.skipReason!) {
                                Button(String(localized: "Open \(item.saved.appName)")) {
                                    Task { await model.openAndPlace(bundleID: item.saved.bundleID, workspace: workspace) }
                                }
                                .controlSize(.small)
                                .disabled(model.isBusy)
                            }
                        }
                        .padding(.horizontal, 16).padding(.vertical, 5)
                    }
                }
            }
            .padding(.bottom, 12)
        }
    }

    private func destination(_ item: PlanItem) -> String {
        guard case .move(_, _, let displayID) = item.kind else { return "" }
        return model.displays.first { $0.id == displayID }?.name ?? ""
    }

    private func header(_ text: String, color: Color = .secondary) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)
    }

    private func row(_ saved: SavedWindow, detail: String?, trailing: String) -> some View {
        HStack(spacing: 9) {
            AppIconView(bundleID: saved.bundleID, size: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: saved.appName).font(.system(size: 12))
                if let detail, !detail.isEmpty {
                    Text(verbatim: detail).font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer()
            Text(verbatim: trailing).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 16).padding(.vertical, 5)
    }
}

