import AppKit
import Carbon
import OrbitCore

@MainActor final class GlobalShortcuts {
  static var isHolding = false
  private var push: EventHotKeyRef?, sessions: EventHotKeyRef?, escape: EventHotKeyRef?
  private var handler: EventHandlerRef?
  private var localMonitor: Any?
  private var signature: [UInt32] = []
  private weak var controller: OrbitController?
  var toggle: (() -> Void)?
  init(_ controller: OrbitController) {
    self.controller = controller
    var types = [
      EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
      EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
    ]
    InstallEventHandler(
      GetApplicationEventTarget(),
      { _, event, context in
        guard let event, let context else { return OSStatus(eventNotHandledErr) }
        var key = EventHotKeyID()
        GetEventParameter(
          event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
          MemoryLayout<EventHotKeyID>.size, nil, &key)
        let owner = Unmanaged<GlobalShortcuts>.fromOpaque(context).takeUnretainedValue()
        let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
        MainActor.assumeIsolated { owner.received(key.id, pressed: pressed) }
        return noErr
      }, types.count, &types, Unmanaged.passUnretained(self).toOpaque(), &handler)
    localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) {
      [weak self] event in
      guard let self, let controller = self.controller else { return event }
      let settings = controller.settings
      let modifiers = Self.carbon(event.modifierFlags)
      if event.type == .flagsChanged {
        if Self.isHolding && modifiers != settings.pushModifiers {
          self.received(1, pressed: false)
        }
        return event
      }
      let pressed = event.type == .keyDown
      if UInt32(event.keyCode) == settings.pushKey
        && (modifiers == settings.pushModifiers || Self.isHolding)
      {
        if !event.isARepeat { self.received(1, pressed: pressed) }
        return nil
      }
      if UInt32(event.keyCode) == settings.sessionsKey && modifiers == settings.sessionsModifiers {
        if pressed && !event.isARepeat { self.received(2, pressed: true) }
        return nil
      }
      return event
    }
    sync()
  }
  func sync() {
    guard let controller else { return }
    let s = controller.settings
    let new = [s.pushKey, s.pushModifiers, s.sessionsKey, s.sessionsModifiers]
    if new != signature {
      if let push { UnregisterEventHotKey(push) }
      if let sessions { UnregisterEventHotKey(sessions) }
      self.push = nil
      self.sessions = nil
      signature = new
      let a = RegisterEventHotKey(
        s.pushKey, s.pushModifiers, EventHotKeyID(signature: 0x4F52_4254, id: 1),
        GetApplicationEventTarget(), 0, &push)
      let b = RegisterEventHotKey(
        s.sessionsKey, s.sessionsModifiers, EventHotKeyID(signature: 0x4F52_4254, id: 2),
        GetApplicationEventTarget(), 0, &sessions)
      if a != noErr || b != noErr {
        controller.error =
          "Una scorciatoia è già occupata. Scegli un’altra combinazione in Generale."
      }
    }
    if controller.isListening || controller.isInterpreting {
      if escape == nil {
        RegisterEventHotKey(
          53, 0, EventHotKeyID(signature: 0x4F52_4254, id: 3), GetApplicationEventTarget(), 0,
          &escape)
      }
    } else if let escape {
      UnregisterEventHotKey(escape)
      self.escape = nil
    }
  }
  private func received(_ id: UInt32, pressed: Bool) {
    switch id {
    case 1:
      Self.isHolding = pressed
      if pressed { controller?.beginListening() } else { controller?.finishListening() }
    case 2: if pressed { toggle?() }
    case 3:
      if pressed {
        Self.isHolding = false
        controller?.cancelListening()
      }
    default: break
    }
  }
  func stop() {
    if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    localMonitor = nil
    if let push { UnregisterEventHotKey(push) }
    if let sessions { UnregisterEventHotKey(sessions) }
    if let escape { UnregisterEventHotKey(escape) }
    if let handler { RemoveEventHandler(handler) }
  }
  static func carbon(_ flags: NSEvent.ModifierFlags) -> UInt32 {
    var result: UInt32 = 0
    if flags.contains(.command) { result |= UInt32(cmdKey) }
    if flags.contains(.shift) { result |= UInt32(shiftKey) }
    if flags.contains(.option) { result |= UInt32(optionKey) }
    if flags.contains(.control) { result |= UInt32(controlKey) }
    return result
  }
  static func label(key: UInt32, modifiers: UInt32) -> String {
    var text = ""
    for (flag, symbol) in [
      (UInt32(controlKey), "⌃"), (UInt32(optionKey), "⌥"), (UInt32(shiftKey), "⇧"),
      (UInt32(cmdKey), "⌘"),
    ] where modifiers & flag != 0 { text += symbol }
    let names: [UInt32: String] = [
      49: "Spazio", 31: "O", 0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C",
      9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 32: "U", 34: "I",
      35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M", 36: "Invio", 48: "Tab",
    ]
    return text + (names[key] ?? "Tasto \(key)")
  }
}
