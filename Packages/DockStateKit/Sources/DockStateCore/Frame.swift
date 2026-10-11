import Foundation

/// A rectangle in points.
///
/// Global frames use the CoreGraphics / Accessibility convention: the origin is the
/// top-left corner of the primary display and y grows downwards. AppKit's bottom-left
/// coordinates are converted in the system layer before they reach the core.
public struct Frame: Codable, Hashable, Sendable, CustomStringConvertible {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let zero = Frame(x: 0, y: 0, width: 0, height: 0)

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
    public var area: Double { max(0, width) * max(0, height) }
    public var isEmpty: Bool { width <= 0 || height <= 0 }

    public func offsetBy(dx: Double, dy: Double) -> Frame {
        Frame(x: x + dx, y: y + dy, width: width, height: height)
    }

    public func contains(x px: Double, y py: Double) -> Bool {
        px >= x && px < maxX && py >= y && py < maxY
    }

    public func intersection(_ other: Frame) -> Frame {
        let nx = max(x, other.x), ny = max(y, other.y)
        let nmx = min(maxX, other.maxX), nmy = min(maxY, other.maxY)
        guard nmx > nx, nmy > ny else { return .zero }
        return Frame(x: nx, y: ny, width: nmx - nx, height: nmy - ny)
    }

    /// True when every edge is within `tolerance` points.
    public func isApproximatelyEqual(to other: Frame, tolerance: Double = 2) -> Bool {
        abs(x - other.x) <= tolerance && abs(y - other.y) <= tolerance
            && abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }

    /// Shrinks the frame to fit `bounds` and then moves it fully inside.
    public func clamped(into bounds: Frame) -> Frame {
        let w = min(width, bounds.width), h = min(height, bounds.height)
        let nx = min(max(x, bounds.x), bounds.maxX - w)
        let ny = min(max(y, bounds.y), bounds.maxY - h)
        return Frame(x: nx, y: ny, width: w, height: h)
    }

    public var description: String {
        "(\(Int(x.rounded())), \(Int(y.rounded())), \(Int(width.rounded()))×\(Int(height.rounded())))"
    }
}
