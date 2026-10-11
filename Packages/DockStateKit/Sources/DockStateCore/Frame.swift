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

    /// Whether a window at `self` counts as being at `target`.
    ///
    /// Position must match closely; size is more lenient because many apps can't take
    /// every size (minimum sizes, Terminal's character grid, fixed-size windows).
    public func isPlacementEquivalent(to target: Frame) -> Bool {
        let p = PlacementTolerance.self
        let sizeTolerance: (Double) -> Double = { max(p.size, $0 * p.sizeFraction) }
        return abs(x - target.x) <= p.position && abs(y - target.y) <= p.position
            && abs(width - target.width) <= sizeTolerance(target.width)
            && abs(height - target.height) <= sizeTolerance(target.height)
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

/// Shared tolerances for "is this window where it should be", used by the planner and by
/// the Accessibility mover's read-back so the two never disagree.
public enum PlacementTolerance {
    /// Points a window's origin may differ from its target.
    public static let position: Double = 4
    /// Minimum points a window's size may differ from its target.
    public static let size: Double = 8
    /// Fraction of the target size that may differ (whichever is larger).
    public static let sizeFraction: Double = 0.03
}
