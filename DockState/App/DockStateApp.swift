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

    var body: some View {
        Image(nsImage: MenuBarIcon.image(badge: model.needsAttention))
            .accessibilityLabel(model.needsAttention ? Text("DockState, needs attention") : Text(verbatim: "DockState"))
    }
}
