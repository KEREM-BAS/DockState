import Foundation

/// Everything DockState knows about one connected display.
///
/// Identity is deliberately layered because no single attribute is reliable:
/// - `uuid` (ColorSync display UUID) is stable for a given panel but can change when
///   the same monitor is connected through a different port or adapter.
/// - `serialNumber` comes from EDID and is often 0 on cheap monitors and for pairs
///   of identical monitors.
/// - `vendorID` / `modelID` identify the model, not the unit.
/// - The arrangement (`frame`) disambiguates identical monitors.
public struct DisplayDescriptor: Codable, Hashable, Sendable, Identifiable {
    /// Stable key inside a saved workspace (the UUID when available).
    public var id: String
    public var uuid: String?
    public var vendorID: UInt32
    public var modelID: UInt32
    public var serialNumber: UInt32
    public var name: String
    public var isBuiltin: Bool
    public var isMain: Bool
    /// Global frame in points (top-left origin).
    public var frame: Frame
    /// Frame minus menu bar and Dock, same coordinate space as `frame`.
    public var visibleFrame: Frame
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var scale: Double

    public init(
        id: String, uuid: String?, vendorID: UInt32, modelID: UInt32, serialNumber: UInt32,
        name: String, isBuiltin: Bool, isMain: Bool, frame: Frame, visibleFrame: Frame,
        pixelWidth: Int, pixelHeight: Int, scale: Double
    ) {
        self.id = id
        self.uuid = uuid
        self.vendorID = vendorID
        self.modelID = modelID
        self.serialNumber = serialNumber
        self.name = name
        self.isBuiltin = isBuiltin
        self.isMain = isMain
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scale = scale
    }

    /// A short human readable spec, e.g. "2560 × 1440".
    public var resolutionText: String { "\(Int(frame.width)) × \(Int(frame.height))" }
}

public extension Array where Element == DisplayDescriptor {
    /// Identifies a display configuration: which displays, where, at what resolution.
    /// Deliberately ignores `visibleFrame`, which changes when the Dock moves or hides.
    var setupKey: String {
        // Duplicate-id suffixes ("#2") depend on enumeration order, so they're left out;
        // the frames already tell identical displays apart.
        map { "\($0.id.split(separator: "#").first.map(String.init) ?? $0.id)@\(Int($0.frame.x)),\(Int($0.frame.y)) \(Int($0.frame.width))x\(Int($0.frame.height))/\($0.pixelWidth)x\($0.pixelHeight)" }
            .sorted()
            .joined(separator: "|")
    }

    /// Makes ids unique (identical monitors can report the same UUID) by suffixing duplicates.
    func uniquingIDs() -> [DisplayDescriptor] {
        var seen: [String: Int] = [:]
        return map { d in
            var d = d
            let n = seen[d.id, default: 0]
            seen[d.id] = n + 1
            if n > 0 { d.id += "#\(n + 1)" }
            return d
        }
    }

    /// The display containing the centre of `frame`, or the one it overlaps most.
    func display(containing frame: Frame) -> DisplayDescriptor? {
        if let hit = first(where: { $0.frame.contains(x: frame.midX, y: frame.midY) }) { return hit }
        return self.max { $0.frame.intersection(frame).area < $1.frame.intersection(frame).area }
            .flatMap { $0.frame.intersection(frame).area > 0 ? $0 : nil }
    }
}
