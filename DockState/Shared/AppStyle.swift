import AppKit
import SwiftUI
import DockStateCore
import DockStateSystem

enum AppStyle {
    /// A stable, pleasant colour per app so the same app looks the same on every map.
    static func color(for bundleID: String) -> Color {
        var hash: UInt64 = 1469598103934665603
        for b in bundleID.utf8 { hash = (hash ^ UInt64(b)) &* 1099511628211 }
        let hue = Double(hash % 360) / 360
        return Color(hue: hue, saturation: 0.45, brightness: 0.78)
    }

    /// Black or white, whichever reads better on `fill` (WCAG relative luminance).
    static func labelColor(on fill: Color) -> Color {
        guard let c = NSColor(fill).usingColorSpace(.sRGB) else { return .white }
        func linear(_ v: CGFloat) -> Double {
            let v = Double(v)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let l = 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
        // Contrast with white is (1.05)/(l+0.05); with black (l+0.05)/0.05. Pick the higher.
        return (1.05 / (l + 0.05)) >= ((l + 0.05) / 0.05) ? .white : .black.opacity(0.85)
    }
}

/// The app's icon, or a coloured tile when the app isn't installed.
struct AppIconView: View {
    var bundleID: String
    var size: CGFloat = 16

    var body: some View {
        if let icon = AppLauncher.icon(for: bundleID) {
            Image(nsImage: icon).resizable().frame(width: size, height: size)
        } else {
            RoundedRectangle(cornerRadius: size * 0.25).fill(AppStyle.color(for: bundleID)).frame(width: size, height: size)
        }
    }
}

/// DockState's mark: a window and a smaller window docked against it.
struct DockStateMark: View {
    var size: CGFloat = 64

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
            .fill(Color.accentColor.gradient)
            .frame(width: size, height: size)
            .overlay {
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: size * 0.05)
                        .strokeBorder(.white, lineWidth: size * 0.047)
                        .frame(width: size * 0.42, height: size * 0.3)
                        .offset(x: size * 0.18, y: size * 0.28)
                    RoundedRectangle(cornerRadius: size * 0.05)
                        .fill(Color.accentColor)
                        .overlay(RoundedRectangle(cornerRadius: size * 0.05).strokeBorder(.white, lineWidth: size * 0.047))
                        .frame(width: size * 0.26, height: size * 0.22)
                        .offset(x: size * 0.52, y: size * 0.37)
                }
                .frame(width: size, height: size, alignment: .topLeading)
            }
            .shadow(color: .black.opacity(0.18), radius: size * 0.06, y: size * 0.03)
            .accessibilityHidden(true)
    }
}

/// Builds the menu bar icon; drawn in code so it stays crisp and template-tinted.
enum MenuBarIcon {
    static func image(badge: Bool) -> NSImage {
        let size = NSSize(width: 20, height: 16)
        let image = NSImage(size: size, flipped: true) { _ in
            NSColor.black.setStroke()
            let back = NSBezierPath(roundedRect: NSRect(x: 2, y: 3.5, width: 10, height: 8), xRadius: 1.5, yRadius: 1.5)
            back.lineWidth = 1.5
            back.stroke()
            let front = NSRect(x: 9.5, y: 6.5, width: 7, height: 6)
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(roundedRect: front.insetBy(dx: -1, dy: -1), xRadius: 2, yRadius: 2).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            let frontPath = NSBezierPath(roundedRect: front, xRadius: 1.5, yRadius: 1.5)
            frontPath.lineWidth = 1.5
            frontPath.stroke()
            if badge {
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: 15, y: 0.5, width: 5, height: 5)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "DockState"
        return image
    }
}
