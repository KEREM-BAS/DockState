import AppKit
import Carbon.HIToolbox

/// The actions that can have a global keyboard shortcut.
enum ShortcutAction: String, CaseIterable, Codable, Identifiable {
    case save, restore, undo
    var id: String { rawValue }

    var hotKeyID: UInt32 {
        switch self {
        case .save: 1
        case .restore: 2
        case .undo: 3
        }
    }

    var title: String {
        switch self {
        case .save: String(localized: "Save current layout")
        case .restore: String(localized: "Restore matching workspace")
        case .undo: String(localized: "Undo last restore")
        }
    }

    /// Suggested when shortcuts are turned on for the first time.
    var defaultCombo: KeyCombo {
        switch self {
        case .save: KeyCombo(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(cmdKey | optionKey), key: "S")
        case .restore: KeyCombo(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(cmdKey | optionKey), key: "R")
        case .undo: KeyCombo(keyCode: UInt32(kVK_ANSI_Z), modifiers: UInt32(cmdKey | optionKey), key: "Z")
        }
    }
}

/// A key plus modifiers, in Carbon terms (what RegisterEventHotKey takes).
struct KeyCombo: Codable, Hashable {
    var keyCode: UInt32
    var modifiers: UInt32
    /// The key's label as typed, e.g. "S" or "F5".
    var key: String

    /// "⌃⌥⇧⌘S" in the standard macOS order.
    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + key
    }

    /// Builds a combo from a key press; nil unless it has ⌘, ⌥ or ⌃ (a global shortcut
    /// without them would swallow normal typing).
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.command, .option, .control]).isEmpty else { return nil }
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        let code = UInt32(event.keyCode)
        let label = Self.specialKeys[Int(code)] ?? event.charactersIgnoringModifiers?.uppercased() ?? ""
        guard !label.isEmpty, !label.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        self.init(keyCode: code, modifiers: carbon, key: label)
    }

    init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    private static let specialKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_ForwardDelete: "⌦",
    ]
}

/// System-wide keyboard shortcuts through Carbon's RegisterEventHotKey — public API that
/// needs no extra permission (unlike event taps).
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var handlers: [UInt32: @MainActor () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlerInstalled = false

    /// Registers a shortcut. Returns false when macOS refuses it (another app or the
    /// system already owns that combination).
    @discardableResult
    func register(_ id: UInt32, _ combo: KeyCombo, handler: @escaping @MainActor () -> Void) -> Bool {
        installHandlerIfNeeded()
        unregister(id)
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4453_5441), id: id) // 'DSTA'
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs[id] = ref
        handlers[id] = handler
        return true
    }

    func unregister(_ id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        handlers[id] = nil
    }

    func unregisterAll() {
        for id in Array(refs.keys) { unregister(id) }
    }

    fileprivate func fire(_ id: UInt32) {
        handlers[id]?()
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKeyCenter.shared.fire(id) } }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
