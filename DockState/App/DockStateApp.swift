import SwiftUI
import DockStateCore

@main
struct DockStateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarPopover()
                .environment(delegate.model)
                .environment(delegate.actions)
        } label: {
            MenuBarLabel(model: delegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarLabel: View {
    var model: AppModel
    @State private var frame = 0

    var body: some View {
        let state = model.menuBarState
        Image(nsImage: MenuBarIcon.image(for: state, frame: frame))
            .accessibilityLabel(Text(MenuBarIcon.accessibilityDescription(for: state)))
            .task(id: state == .restoring) {
                // Animate only while restoring; no timers otherwise.
                guard state == .restoring else { frame = 0; return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(120))
                    frame += 1
                }
            }
    }
}
