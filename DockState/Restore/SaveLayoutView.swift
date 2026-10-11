import SwiftUI
import DockStateCore

/// "Save Current Layout" (design save sheet). Saving with an existing name replaces it.
struct SaveLayoutView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppActions.self) private var actions
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let replaces = model.workspace(named: trimmed) != nil
        let count = model.capturableWindows.count
        VStack(alignment: .leading, spacing: 12) {
            Text(description(count: count))
                .font(.system(size: 12.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField(String(localized: "Workspace name"), text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(save)
            if replaces {
                Text("This replaces the saved layout for “\(trimmed)”.")
                    .font(.system(size: 11.5)).foregroundStyle(.orange)
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { actions.closeSave() }
                    .keyboardShortcut(.cancelAction)
                Button(replaces ? String(localized: "Replace") : String(localized: "Save"), action: save)
                    .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                    .disabled(trimmed.isEmpty || count == 0)
            }
        }
        .padding(20)
        .frame(width: 420, height: 190)
        .task {
            await model.refresh()
            if name.isEmpty { name = model.suggestedName() }
            focused = true
        }
    }

    private func description(count: Int) -> String {
        if !model.permissionGranted { return String(localized: "DockState needs Accessibility permission to see your windows.") }
        if count == 0 { return String(localized: "No windows found on this Space.") }
        let where_ = model.displays.count == 1 && model.displays[0].isBuiltin
            ? String(localized: "the built-in display")
            : String(localized: "\(model.displays.count) displays")
        return String(localized: "\(count) windows on \(where_) will be saved as a workspace.")
    }

    private func save() {
        guard let ws = model.saveCurrentLayout(named: name) else { return }
        actions.closeSave()
        model.presenter?.toast(String(localized: "Saved “\(ws.name)”"))
    }
}
