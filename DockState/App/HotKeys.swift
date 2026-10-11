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
    /// The key's label when it was recorded; only a fallback, the label shown is worked
    /// out from the current keyboard layout and language.
    var key: String

    static let modifierMask = UInt32(cmdKey | optionKey | controlKey | shiftKey)

    /// "⌃⌥⇧⌘S" in the standard macOS order.
    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + keyLabel
    }

    var keyLabel: String {
        if let special = Self.specialKeyLabel(Int(keyCode)) { return special }
        return Self.character(forKeyCode: keyCode) ?? key
    }

    enum RejectionReason: Error, Equatable {
        /// Needs ⌃, or two of ⌘ ⌥ ⌃ — otherwise it would take over normal typing or a
        /// standard command such as ⌘W in every app.
        case tooSimple
        case notAKey
    }

    /// Builds a combo from a key press, or says why that key press can't be a global shortcut.
    static func from(event: NSEvent) -> Result<KeyCombo, RejectionReason> {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let strong = [flags.contains(.command), flags.contains(.option), flags.contains(.control)].filter { $0 }.count
        guard flags.contains(.control) || strong >= 2 else { return .failure(.tooSimple) }
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        let code = UInt32(event.keyCode)
        let label = specialKeyLabel(Int(code)) ?? character(forKeyCode: code) ?? event.charactersIgnoringModifiers?.uppercased() ?? ""
        guard !label.isEmpty, !label.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return .failure(.notAKey)
        }
        return .success(KeyCombo(keyCode: code, modifiers: carbon, key: label))
    }

    init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    /// Whether macOS itself uses this combination (Spotlight, screenshots, Mission Control…).
    var isReservedBySystem: Bool {
        var ref: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&ref) == noErr, let list = ref?.takeRetainedValue() as? [[String: Any]] else { return false }
        return list.contains { entry in
            guard (entry["kHISymbolicHotKeyEnabled"] as? Bool) == true,
                  let code = (entry["kHISymbolicHotKeyCode"] as? NSNumber)?.uint32Value,
                  let mods = (entry["kHISymbolicHotKeyModifiers"] as? NSNumber)?.uint32Value else { return false }
            return code == keyCode && (mods & Self.modifierMask) == (modifiers & Self.modifierMask)
        }
    }

    /// The character a key types on the current keyboard layout, e.g. "Z" or "Y" for the
    /// same key on a German layout.
    static func character(forKeyCode keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> String? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeys: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
            guard status == noErr, length > 0 else { return nil }
            let text = String(utf16CodeUnits: chars, count: length).uppercased()
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
        }
    }

    static func specialKeyLabel(_ code: Int) -> String? {
        switch code {
        case kVK_Space: String(localized: "Space")
        case kVK_F1: "F1"
        case kVK_F2: "F2"
        case kVK_F3: "F3"
        case kVK_F4: "F4"
        case kVK_F5: "F5"
        case kVK_F6: "F6"
        case kVK_F7: "F7"
        case kVK_F8: "F8"
        case kVK_F9: "F9"
        case kVK_F10: "F10"
        case kVK_F11: "F11"
        case kVK_F12: "F12"
        case kVK_LeftArrow: "←"
        case kVK_RightArrow: "→"
        case kVK_UpArrow: "↑"
        case kVK_DownArrow: "↓"
        case kVK_Return: "↩"
        case kVK_Tab: "⇥"
        case kVK_Home: "↖"
        case kVK_End: "↘"
        case kVK_PageUp: "⇞"
        case kVK_PageDown: "⇟"
        case kVK_ForwardDelete: "⌦"
        default: nil
        }
    }
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
