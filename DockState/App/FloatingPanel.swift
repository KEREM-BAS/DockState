import AppKit
import SwiftUI

/// A borderless, non-activating panel for transient UI (result card, toast) that floats
/// above other windows without stealing focus.
@MainActor
final class FloatingPanel {
    enum Placement { case topTrailing, bottomCenter }

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private var hideDelay: Duration?
    private var generation = 0

    /// - Parameters:
    ///   - announcement: read out by VoiceOver, since the panel never takes focus.
    ///   - autoHideAfter: paused while the pointer is over the panel; tripled with VoiceOver on.
    func show<Content: View>(placement: Placement, announcement: String? = nil, autoHideAfter: Duration? = nil,
                             @ViewBuilder content: () -> Content) {
        hideTask?.cancel()
        generation += 1
        let host = NSHostingView(rootView: content().fixedSize().onHover { [weak self] inside in
            inside ? self?.pauseHiding() : self?.scheduleHide()
        })
        let size = host.fittingSize
        let panel = self.panel ?? Self.makePanel()
        panel.contentView = host
        panel.setContentSize(size)
        // The screen with the menu bar the user clicked, else the one with the pointer.
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main {
            let vf = screen.visibleFrame
            let origin: NSPoint = switch placement {
            case .topTrailing: NSPoint(x: vf.maxX - size.width - 12, y: vf.maxY - size.height - 8)
            case .bottomCenter: NSPoint(x: vf.midX - size.width / 2, y: vf.minY + 28)
            }
            panel.setFrameOrigin(origin)
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; panel.animator().alphaValue = 1 }
        self.panel = panel
        if let announcement { Self.announce(announcement) }
        hideDelay = autoHideAfter.map { NSWorkspace.shared.isVoiceOverEnabled ? $0 * 3 : $0 }
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard let delay = hideDelay else { return }
        let mine = generation
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.generation == mine else { return }
            self.hide()
        }
    }

    private func pauseHiding() {
        hideTask?.cancel()
    }

    func hide() {
        hideTask?.cancel()
        guard let panel else { return }
        let mine = generation
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; panel.animator().alphaValue = 0 }) { [weak self] in
            MainActor.assumeIsolated {
                // A newer show() may have reused the panel while this fade ran.
                guard self?.generation == mine else { return }
                panel.orderOut(nil)
            }
        }
    }

    /// Asks VoiceOver to read `message`.
    static func announce(_ message: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: message,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        return panel
    }
}

/// The rounded card look shared by floating UI.
struct CardBackground: ViewModifier {
    var radius: CGFloat = 12

    func body(content: Content) -> some View {
        content
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
            .padding(1)
    }
}

extension View {
    func card(radius: CGFloat = 12) -> some View { modifier(CardBackground(radius: radius)) }
}

/// Prominent button for non-activating panels, where `.borderedProminent` renders in the
/// inactive (grey) style because the panel never becomes key.
struct AccentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(.white)
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(Color.accentColor.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 6))
            .opacity(isEnabled ? 1 : 0.5)
    }
}

/// Secondary counterpart of `AccentButtonStyle`.
struct PanelButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5))
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(Color.primary.opacity(configuration.isPressed ? 0.16 : 0.09), in: RoundedRectangle(cornerRadius: 6))
            .opacity(isEnabled ? 1 : 0.45)
    }
}
