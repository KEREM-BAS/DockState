import SwiftUI
import DockStateCore

/// One rectangle drawn on the layout map.
struct MapBox: Identifiable, Equatable {
    enum Style: Equatable {
        /// A window where it is / will be.
        case solid
        /// Where a window is now, before it moves.
        case origin
        /// A saved window that can't be restored.
        case missing
        /// A saved window the user excluded from restoring.
        case excluded
    }

    var id: String
    var frame: Frame
    var color: Color
    var label: String
    var style: Style
}

/// A schematic of the displays and windows, scaled to fit. No screenshots are taken —
/// which is why DockState never needs Screen Recording permission.
struct LayoutMapView: View {
    var displays: [DisplayDescriptor]
    var boxes: [MapBox]
    var showLabels = true

    var body: some View {
        GeometryReader { geo in
            let t = MapTransform(displays: displays, size: geo.size)
            ZStack(alignment: .topLeading) {
                ForEach(displays) { d in
                    let r = t.rect(d.frame)
                    RoundedRectangle(cornerRadius: max(3, r.width * 0.02))
                        .fill(Color.primary.opacity(0.07))
                        .overlay(
                            RoundedRectangle(cornerRadius: max(3, r.width * 0.02))
                                .strokeBorder(Color.primary.opacity(0.55), lineWidth: max(2, r.width * 0.014)))
                        .frame(width: r.width, height: r.height)
                        .offset(x: r.minX, y: r.minY)
                        .accessibilityLabel(d.name)
                }
                ForEach(Self.drawingOrder(boxes)) { box in
                    let r = t.rect(box.frame)
                    boxView(box, size: r.size)
                        .frame(width: max(r.width, 2), height: max(r.height, 2))
                        .offset(x: r.minX, y: r.minY)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        // The drawing is a picture; VoiceOver gets a one-line summary instead of every box.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Layout of \(boxes.filter { $0.style != .origin }.count) windows on \(displays.count) displays"))
    }

    /// Outlines of where windows are now first, then windows from largest to smallest so
    /// small windows stay visible on top of big ones, then dashed markers.
    static func drawingOrder(_ boxes: [MapBox]) -> [MapBox] {
        func rank(_ b: MapBox) -> Int {
            switch b.style {
            case .origin: 0
            case .solid, .excluded: 1
            case .missing: 2
            }
        }
        return boxes.enumerated().sorted { a, b in
            let ra = rank(a.element), rb = rank(b.element)
            if ra != rb { return ra < rb }
            if a.element.frame.area != b.element.frame.area { return a.element.frame.area > b.element.frame.area }
            return a.offset < b.offset
        }.map(\.element)
    }

    @ViewBuilder
    private func boxView(_ box: MapBox, size: CGSize) -> some View {
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
        switch box.style {
        case .solid:
            shape.fill(box.color)
                .overlay(shape.strokeBorder(.black.opacity(0.15), lineWidth: 0.5))
                .overlay(alignment: .topLeading) { label(box.label, color: AppStyle.labelColor(on: box.color), size: size) }
                .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
        case .excluded:
            shape.fill(box.color.opacity(0.18))
                .overlay(shape.strokeBorder(box.color, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                .overlay(alignment: .topLeading) { label(box.label, color: .secondary, size: size) }
        case .origin:
            shape.strokeBorder(Color.secondary, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
        case .missing:
            shape.strokeBorder(Color.secondary.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                .overlay(alignment: .topLeading) { label(box.label, color: .secondary, size: size) }
        }
    }

    @ViewBuilder
    private func label(_ text: String, color: Color, size: CGSize) -> some View {
        if showLabels, size.width > 34, size.height > 14 {
            Text(verbatim: text)
                .font(.system(size: min(11, max(8, size.height * 0.18)), weight: .medium))
                .foregroundStyle(color)
                .lineLimit(1)
                .padding(.horizontal, 4)
                .padding(.top, 2)
        }
    }
}

/// Maps global display coordinates into the view, preserving aspect ratio.
struct MapTransform {
    let scale: Double
    let dx: Double
    let dy: Double

    init(displays: [DisplayDescriptor], size: CGSize, padding: Double = 6) {
        let frames = displays.map(\.frame)
        let minX = frames.map(\.x).min() ?? 0, minY = frames.map(\.y).min() ?? 0
        let maxX = frames.map(\.maxX).max() ?? 1, maxY = frames.map(\.maxY).max() ?? 1
        let w = max(maxX - minX, 1), h = max(maxY - minY, 1)
        let avail = (Double(size.width) - padding * 2, Double(size.height) - padding * 2)
        scale = max(0.0001, min(avail.0 / w, avail.1 / h))
        dx = padding + (avail.0 - w * scale) / 2 - minX * scale
        dy = padding + (avail.1 - h * scale) / 2 - minY * scale
    }

    func rect(_ f: Frame) -> CGRect {
        CGRect(x: f.x * scale + dx, y: f.y * scale + dy, width: f.width * scale, height: f.height * scale)
    }
}
