import Foundation

/// What DockState does when a workspace's displays connect.
public enum AutoMode: String, Codable, Sendable, CaseIterable {
    /// Show a notification and wait for the user (default).
    case ask
    /// Restore right away; the user explicitly opted in and can undo.
    case always
    /// Stay quiet; restore only from the menu.
    case never
}

/// One window's saved placement.
public struct SavedWindow: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var bundleID: String
    public var appName: String
    /// Only stored when the user allows window titles to be used for matching.
    public var title: String?
    public var role: String?
    public var subrole: String?
    /// `DisplayDescriptor.id` of the display the window was on.
    public var displayID: String
    /// Frame relative to the top-left corner of that display, in points.
    public var frameInDisplay: Frame
    /// Front-to-back position among this app's windows at save time (0 = frontmost).
    public var appOrder: Int
    /// Excluded windows are kept but never moved.
    public var isExcluded: Bool

    public init(
        id: UUID = UUID(), bundleID: String, appName: String, title: String?, role: String?,
        subrole: String?, displayID: String, frameInDisplay: Frame, appOrder: Int, isExcluded: Bool = false
    ) {
        self.id = id
        self.bundleID = bundleID
        self.appName = appName
        self.title = title
        self.role = role
        self.subrole = subrole
        self.displayID = displayID
        self.frameInDisplay = frameInDisplay
        self.appOrder = appOrder
        self.isExcluded = isExcluded
    }

    enum CodingKeys: String, CodingKey {
        case id, bundleID, appName, title, role, subrole, displayID, frameInDisplay, appOrder, isExcluded
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        bundleID = try c.decode(String.self, forKey: .bundleID)
        appName = try c.decodeIfPresent(String.self, forKey: .appName) ?? bundleID
        title = try c.decodeIfPresent(String.self, forKey: .title)
        role = try c.decodeIfPresent(String.self, forKey: .role)
        subrole = try c.decodeIfPresent(String.self, forKey: .subrole)
        displayID = try c.decode(String.self, forKey: .displayID)
        frameInDisplay = try c.decode(Frame.self, forKey: .frameInDisplay)
        appOrder = try c.decodeIfPresent(Int.self, forKey: .appOrder) ?? 0
        isExcluded = try c.decodeIfPresent(Bool.self, forKey: .isExcluded) ?? false
    }
}

/// A named display setup plus the placement of its windows.
public struct Workspace: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var displays: [DisplayDescriptor]
    public var windows: [SavedWindow]
    public var autoMode: AutoMode
    public var createdAt: Date
    /// When the window layout was last saved (shown as "Saved …").
    public var updatedAt: Date
    /// When the user last restored this workspace; breaks ties between workspaces saved
    /// for the same displays.
    public var lastRestoredAt: Date?

    public init(
        id: UUID = UUID(), name: String, displays: [DisplayDescriptor], windows: [SavedWindow],
        autoMode: AutoMode = .ask, createdAt: Date = Date(), updatedAt: Date = Date(), lastRestoredAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.displays = displays
        self.windows = windows
        self.autoMode = autoMode
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastRestoredAt = lastRestoredAt
    }

    enum CodingKeys: String, CodingKey { case id, name, displays, windows, autoMode, createdAt, updatedAt, lastRestoredAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        displays = try c.decode([DisplayDescriptor].self, forKey: .displays)
        windows = try c.decodeIfPresent([SavedWindow].self, forKey: .windows) ?? []
        // Unknown modes written by a newer version fall back to the safe default.
        autoMode = (try? c.decode(AutoMode.self, forKey: .autoMode)) ?? .ask
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        lastRestoredAt = try c.decodeIfPresent(Date.self, forKey: .lastRestoredAt)
    }

    public func display(id: String) -> DisplayDescriptor? { displays.first { $0.id == id } }

    /// Removes stored window titles (used when the user turns title matching off).
    public func strippingTitles() -> Workspace {
        var copy = self
        copy.windows = windows.map { var w = $0; w.title = nil; return w }
        return copy
    }
}
