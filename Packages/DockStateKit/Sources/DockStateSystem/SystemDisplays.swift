import AppKit
import CoreGraphics
import DockStateCore

/// Reads the connected displays from CoreGraphics and AppKit.
///
/// Mirrored displays are collapsed: only the display that others mirror is reported,
/// because windows can't be placed independently on a mirror.
@MainActor
public enum SystemDisplays {
    public static func current() -> [DisplayDescriptor] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }

        let screens = NSScreen.screens
        // AppKit uses bottom-left coordinates anchored at the primary screen.
        let primaryHeight = screens.first?.frame.height ?? CGDisplayBounds(CGMainDisplayID()).height

        return ids.prefix(Int(count)).compactMap { id -> DisplayDescriptor? in
            guard CGDisplayMirrorsDisplay(id) == kCGNullDirectDisplay else { return nil }
            let bounds = CGDisplayBounds(id)
            let screen = screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }
            let frame = Frame(bounds)
            var visible = frame
            if let vf = screen?.visibleFrame {
                visible = Frame(x: vf.minX, y: primaryHeight - vf.maxY, width: vf.width, height: vf.height)
            }
            let uuid = CGDisplayCreateUUIDFromDisplayID(id).flatMap {
                CFUUIDCreateString(nil, $0.takeRetainedValue()) as String?
            }
            let mode = CGDisplayCopyDisplayMode(id)
            let builtin = CGDisplayIsBuiltin(id) != 0
            return DisplayDescriptor(
                id: uuid ?? "display-\(id)",
                uuid: uuid,
                vendorID: CGDisplayVendorNumber(id),
                modelID: CGDisplayModelNumber(id),
                serialNumber: CGDisplaySerialNumber(id),
                name: screen?.localizedName ?? (builtin ? "Built-in Display" : "Display"),
                isBuiltin: builtin,
                isMain: CGDisplayIsMain(id) != 0,
                frame: frame,
                visibleFrame: visible,
                pixelWidth: mode?.pixelWidth ?? Int(bounds.width),
                pixelHeight: mode?.pixelHeight ?? Int(bounds.height),
                scale: Double(screen?.backingScaleFactor ?? 1))
        }
    }
}

extension Frame {
    public init(_ rect: CGRect) {
        self.init(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height)
    }

    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

/// Calls `onChange` once the display configuration has settled after a change,
/// a wake from sleep, or a screen wake.
@MainActor
public final class DisplayChangeObserver {
    private let debouncer: SettleDebouncer
    private var tokens: [NSObjectProtocol] = []
    private let onChange: @MainActor () -> Void

    public init(settleDelay: Duration = .seconds(2), onChange: @escaping @MainActor () -> Void) {
        self.debouncer = SettleDebouncer(delay: settleDelay)
        self.onChange = onChange
    }

    public func start() {
        guard tokens.isEmpty else { return }
        let center = NotificationCenter.default
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let handler: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in self?.signal() }
        }
        tokens.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main, using: handler))
        tokens.append(workspaceCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: handler))
        tokens.append(workspaceCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main, using: handler))
    }

    public func stop() {
        tokens.forEach {
            NotificationCenter.default.removeObserver($0)
            NSWorkspace.shared.notificationCenter.removeObserver($0)
        }
        tokens.removeAll()
        Task { await debouncer.cancel() }
    }

    private func signal() {
        let callback = onChange
        Task {
            await debouncer.signal { await MainActor.run { callback() } }
        }
    }
}
