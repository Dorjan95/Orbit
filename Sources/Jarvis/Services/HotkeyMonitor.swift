import Foundation
import Carbon.HIToolbox
import AppKit

/// §3.6 — global chords via Carbon RegisterEventHotKey. Delivers both
/// kEventHotKeyPressed and kEventHotKeyReleased, needs no Accessibility permission,
/// and the chord is swallowed (never reaches the focused app).
@MainActor
final class HotkeyMonitor {
    static let shared = HotkeyMonitor()

    struct Registration { let id: UInt32; var ref: EventHotKeyRef? }
    private var handlers: [UInt32: (pressed: () -> Void, released: () -> Void)] = [:]
    private var registrations: [UInt32: Registration] = [:]
    private var eventHandler: EventHandlerRef?
    private var nextID: UInt32 = 1
    private static let signature: OSType = 0x434E4454 // 'CNDT'

    private init() { installHandler() }

    private func installHandler() {
        var spec = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                    EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let kind = GetEventKind(event)
            Task { @MainActor in HotkeyMonitor.shared.dispatch(id: hk.id, pressed: kind == UInt32(kEventHotKeyPressed)) }
            return noErr
        }, spec.count, &spec, nil, &eventHandler)
    }

    private func dispatch(id: UInt32, pressed: Bool) {
        guard let h = handlers[id] else { return }
        pressed ? h.pressed() : h.released()
    }

    /// Returns a registration id, or nil if macOS refused (another app owns the chord).
    @discardableResult
    func register(_ hotkey: Hotkey, pressed: @escaping () -> Void, released: @escaping () -> Void = {}) -> UInt32? {
        let id = nextID; nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(hotkey.keyCode, hotkey.modifiers, EventHotKeyID(signature: Self.signature, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return nil }
        registrations[id] = Registration(id: id, ref: ref)
        handlers[id] = (pressed, released)
        return id
    }

    func unregister(_ id: UInt32?) {
        guard let id, let r = registrations.removeValue(forKey: id) else { return }
        if let ref = r.ref { UnregisterEventHotKey(ref) }
        handlers.removeValue(forKey: id)
    }

    /// Probe whether a chord can be registered right now (used by the shortcut recorder).
    func canRegister(_ hotkey: Hotkey) -> Bool {
        var ref: EventHotKeyRef?
        let st = RegisterEventHotKey(hotkey.keyCode, hotkey.modifiers, EventHotKeyID(signature: Self.signature, id: 0xFFFF), GetApplicationEventTarget(), 0, &ref)
        if st == noErr, let ref { UnregisterEventHotKey(ref); return true }
        return false
    }
}

extension Hotkey {
    /// Carbon modifier mask from NSEvent modifier flags.
    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        return m
    }

    /// Modifier glyphs then the key, one entry per keycap.
    var keys: [String] {
        var k: [String] = []
        if modifiers & UInt32(controlKey) != 0 { k.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { k.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { k.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { k.append("⌘") }
        k.append(Self.keyName(keyCode))
        return k
    }

    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + Self.keyName(keyCode)
    }

    static func keyName(_ code: UInt32) -> String {
        let names: [UInt32: String] = [49: "Spazio", 36: "↩", 48: "⇥", 53: "⎋", 51: "⌫", 123: "←", 124: "→", 125: "↓", 126: "↑",
                                       122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"]
        if let n = names[code] { return n }
        // Translate via the current keyboard layout.
        guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return "Tasto \(code)" }
        let data = unsafeBitCast(ptr, to: CFData.self) as Data
        var chars = [UniChar](repeating: 0, count: 4); var len = 0; var dead: UInt32 = 0
        let ok = data.withUnsafeBytes { buf -> OSStatus in
            let layout = buf.baseAddress!.assumingMemoryBound(to: UCKeyboardLayout.self)
            return UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()), UInt32(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
        }
        return ok == noErr && len > 0 ? String(utf16CodeUnits: chars, count: len).uppercased() : "Tasto \(code)"
    }
}
