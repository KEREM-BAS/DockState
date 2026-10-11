import AppKit
import SwiftUI

/// A borderless, non-activating panel for transient UI (result card, toast) that floats
/// above other windows without stealing focus.
@MainActor
final class FloatingPanel {
    enum Placement { case topTrailing, bottomCenter }

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show<Content: View>(placement: Placement, autoHideAfter: Duration? = nil, @ViewBuilder content: () -> Content) {
        hideTask?.cancel()
        let host = NSHostingView(rootView: content().fixedSize())
        let size = host.fittingSize
        let panel = self.panel ?? Self.makePanel()
        panel.contentView = host
        panel.setContentSize(size)
        if let screen = NSScreen.main {
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
        if let delay = autoHideAfter {
            hideTask = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                self?.hide()
            }
        }
    }

    func hide() {
        hideTask?.cancel()
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; panel.animator().alphaValue = 0 }) {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        }
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
