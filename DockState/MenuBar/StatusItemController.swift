import AppKit
import Observation
import SwiftUI

/// The menu bar icon and its panel, built with AppKit so that left- and right-click both
/// open the panel (SwiftUI's `MenuBarExtra` ignores right-click) and so DockState can
/// close it explicitly instead of looking for a private window class.
@MainActor
final class StatusItemController: NSObject {
    static private(set) var shared: StatusItemController?

    private let model: AppModel
    private let actions: AppActions
    private let statusItem: NSStatusItem
    private let panel = MenuBarPanel()
    private var animationTimer: Timer?
    private var animationFrame = 0
    private var outsideClickMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    init(model: AppModel, actions: AppActions) {
        self.model = model
        self.actions = actions
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePanel(_:))
            // Right-click opens the same panel as left-click.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        observeState()
        Self.shared = self
    }

    // MARK: Icon

    /// Re-renders the icon whenever the menu bar state changes.
    private func observeState() {
        let state = withObservationTracking {
            model.menuBarState
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeState() }
        }
        apply(state)
    }

    private func apply(_ state: MenuBarState) {
        if state == .restoring {
            // Animate only while restoring; no timers otherwise.
            if animationTimer == nil {
                animationTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.animationFrame += 1
                        self.render(.restoring)
                    }
                }
            }
        } else {
            animationTimer?.invalidate()
            animationTimer = nil
            animationFrame = 0
        }
        render(state)
    }

    private func render(_ state: MenuBarState) {
        guard let button = statusItem.button else { return }
        button.image = MenuBarIcon.image(for: state, frame: animationFrame)
        button.setAccessibilityLabel(MenuBarIcon.accessibilityDescription(for: state))
        button.toolTip = MenuBarIcon.accessibilityDescription(for: state)
    }

    // MARK: Panel

    @objc private func togglePanel(_ sender: Any?) {
        panel.isVisible ? close() : open()
    }

    func open() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        let content = MenuBarPopover()
            .environment(model)
            .environment(actions)
        // A fresh hosting view per opening, so the popover's refresh task runs every time.
        panel.setContent(content)
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        panel.show(below: buttonFrame)
        button.highlight(true)
        startWatchingForDismissal()
    }

    func close() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        statusItem.button?.highlight(false)
        stopWatchingForDismissal()
    }

    static func close() { shared?.close() }

    private func startWatchingForDismissal() {
        stopWatchingForDismissal()
        // A click anywhere outside DockState closes the panel, like a menu.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    private func stopWatchingForDismissal() {
        if let monitor = outsideClickMonitor { NSEvent.removeMonitor(monitor) }
        outsideClickMonitor = nil
        if let observer = resignObserver { NotificationCenter.default.removeObserver(observer) }
        resignObserver = nil
    }
}

/// A borderless panel that looks like the system's menu bar extra windows: vibrant
/// background, rounded corners, no arrow.
@MainActor
final class MenuBarPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: true)
        // isFloatingPanel resets the level, so it must come first.
        isFloatingPanel = true
        level = .popUpMenu
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        setAccessibilityRole(.popover)
    }

    // Key status lets the popover's buttons and keyboard shortcuts (⌘, ⌘Q, Esc) work.
    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        StatusItemController.close()
    }

    func setContent<Content: View>(_ content: Content) {
        let hosting = NSHostingView(rootView: content)
        let effect = NSVisualEffectView()
        effect.material = .menu
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true
        hosting.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        contentView = effect
        setContentSize(hosting.fittingSize)
    }

    /// Places the panel just below the status item, kept fully on its screen.
    func show(below anchor: NSRect) {
        let size = frame.size
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var x = anchor.midX - size.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        let y = anchor.minY - size.height - 4
        setFrameOrigin(NSPoint(x: x, y: y))
        makeKeyAndOrderFront(nil)
    }
}
