import SwiftUI
import DockStateCore

@main
struct DockStateApp: App {
    var body: some Scene {
        MenuBarExtra("DockState", systemImage: "rectangle.on.rectangle") {
            Text(verbatim: "DockState")
                .padding()
        }
        .menuBarExtraStyle(.window)
    }
}
