import AppKit
import Darwin
import OrbitCore
import SwiftUI

@main struct OrbitApplication {
  @MainActor static func main() {
    if ProcessInfo.processInfo.arguments.contains("--check-resources") {
      guard let bundle = OrbitResources.packaged(in: .main) else {
        print("Missing packaged Orbit resources")
        exit(1)
      }
      let names = [
        "AeroMeshy.usdz", "AeroMeshyMotion.json", "Browser/server.mjs", "Browser/package-lock.json",
      ]
      for name in names {
        guard let root = bundle.url(forResource: "Resources", withExtension: nil),
          FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path)
        else {
          print("Missing resource: \(name)")
          exit(1)
        }
      }
      print("Orbit resources verified: \(bundle.bundleURL.path)")
      return
    }
    let app = NSApplication.shared
    let delegate = OrbitDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    if ProcessInfo.processInfo.arguments.contains("--render-docs") {
      delegate.renderDocumentation()
      return
    }
    app.run()
    withExtendedLifetime(delegate) {}
  }
}
@MainActor final class OrbitDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
  var controller: OrbitController!
  var shortcuts: GlobalShortcuts?
  var status: NSStatusItem?
  var settingsWindow: NSWindow?
  var sessionsPanel: NSPanel?
  var mascotPanel: MovableMascotPanel?
  var voicePanel: NSPanel?
  private var syncing = false
  private var lastMascotSize = 0.0
  private var positionApplied = false
  func applicationDidFinishLaunching(_ notification: Notification) {
    controller = OrbitController()
    controller.audio = AudioCoordinator(controller)
    controller.changed = { [weak self] in self?.sync() }
    controller.openSettings = { [weak self] in self?.showSettings() }
    shortcuts = GlobalShortcuts(controller)
    shortcuts?.toggle = { [weak self] in self?.toggleSessions() }
    setupMenu()
    createPanels()
    controller.setPhase(.greeting, replay: true)
    controller.rest(after: 6)
    controller.audio?.configure()
    sync()
    if !controller.settings.configured
      || (controller.settings.handsFree && controller.voiceNeedsPermission)
      || ProcessInfo.processInfo.arguments.contains("--settings")
    {
      showSettings()
    }
  }
  func setupMenu() {
    status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    status?.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Orbit")
    let menu = NSMenu()
    for (title, selector, key) in [
      ("Parla con Orbit", #selector(talk), ""), ("Sessioni", #selector(sessionAction), ""),
      ("Impostazioni…", #selector(settingsAction), ","),
      ("Apri cartella dati", #selector(openData), ""), ("Esci da Orbit", #selector(quit), "q"),
    ] {
      if title == "Esci da Orbit" { menu.addItem(.separator()) }
      let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
      item.target = self
      menu.addItem(item)
    }
    status?.menu = menu
    let mainMenu = NSMenu()
    let appMenu = NSMenuItem()
    mainMenu.addItem(appMenu)
    appMenu.submenu = menu.copy() as? NSMenu
    let edit = NSMenuItem(title: "Modifica", action: nil, keyEquivalent: "")
    let editMenu = NSMenu(title: "Modifica")
    for (title, selector, key) in [
      ("Annulla", Selector(("undo:")), "z"), ("Taglia", #selector(NSText.cut(_:)), "x"),
      ("Copia", #selector(NSText.copy(_:)), "c"), ("Incolla", #selector(NSText.paste(_:)), "v"),
      ("Seleziona tutto", #selector(NSText.selectAll(_:)), "a"),
    ] { editMenu.addItem(withTitle: title, action: selector, keyEquivalent: key) }
    edit.submenu = editMenu
    mainMenu.addItem(edit)
    NSApp.mainMenu = mainMenu
  }
  @objc func talk() { controller.beginListening() }
  @objc func settingsAction() { showSettings() }
  @objc func sessionAction() { toggleSessions() }
  @objc func openData() { NSWorkspace.shared.open(controller.disk.folder) }
  @objc func quit() { NSApp.terminate(nil) }
  func showSettings() {
    if settingsWindow == nil {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1020, height: 850),
        styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered,
        defer: false)
      window.title = "Orbit"
      window.titlebarAppearsTransparent = true
      window.titleVisibility = .hidden
      window.backgroundColor = NSColor(Palette.background)
      window.contentView = NSHostingView(rootView: OrbitSettingsView(controller: controller))
      window.minSize = NSSize(width: 860, height: 720)
      window.isReleasedWhenClosed = false
      window.delegate = self
      window.center()
      settingsWindow = window
    }
    controller.mainVisible = true
    sessionsPanel?.orderOut(nil)
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    settingsWindow?.makeKeyAndOrderFront(nil)
    sync()
  }
  func toggleSessions() {
    if controller.mainVisible {
      controller.section = .sessions
      showSettings()
      return
    }
    controller.overlayRequested.toggle()
    sync()
    if controller.overlayRequested { sessionsPanel?.makeKeyAndOrderFront(nil) }
  }
  func createPanels() {
    let sessions = SessionPanel(
      contentRect: NSRect(x: 0, y: 0, width: 510, height: 600),
      styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
    prepare(sessions)
    sessions.title = "Sessioni Orbit"
    sessions.backgroundColor = .clear
    sessions.isOpaque = false
    sessions.hasShadow = true
    sessions.isMovableByWindowBackground = true
    sessions.delegate = self
    sessions.minSize = NSSize(width: 490, height: 280)
    sessions.contentView = NSHostingView(rootView: SessionOverlay(controller: controller))
    sessionsPanel = sessions
    let mascot = MovableMascotPanel(
      contentRect: NSRect(x: 0, y: 0, width: 190, height: 278),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    prepare(mascot)
    mascot.title = "Aero"
    mascot.backgroundColor = .clear
    mascot.isOpaque = false
    mascot.hasShadow = false
    mascot.delegate = self
    mascot.clicked = { [weak self] in self?.controller.beginListening() }
    mascot.contentView = NSHostingView(rootView: MascotView(controller: controller))
    mascotPanel = mascot
    let voice = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 480, height: 80),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    prepare(voice)
    voice.title = "Voce Orbit"
    voice.backgroundColor = .clear
    voice.isOpaque = false
    voice.hasShadow = true
    voice.isMovableByWindowBackground = true
    voice.contentView = NSHostingView(rootView: VoiceOverlay(controller: controller))
    voicePanel = voice
  }
  func prepare(_ panel: NSPanel) {
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
  }
  func clamp(_ origin: NSPoint, size: NSSize) -> NSPoint {
    let screens = NSScreen.screens.map(\.visibleFrame)
    let frame = NSRect(origin: origin, size: size)
    let target =
      screens.first { $0.intersects(frame) } ?? NSScreen.main?.visibleFrame
      ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    return NSPoint(
      x: min(max(origin.x, target.minX), target.maxX - size.width),
      y: min(max(origin.y, target.minY), target.maxY - size.height))
  }
  func sync() {
    guard controller != nil, !syncing else { return }
    syncing = true
    defer { syncing = false }
    shortcuts?.sync()
    let s = controller.settings
    let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    if let mascot = mascotPanel {
      if lastMascotSize != s.mascotHeight || !positionApplied {
        let size = NSSize(width: max(190, s.mascotHeight * 0.9), height: s.mascotHeight + 78)
        mascot.setContentSize(size)
        lastMascotSize = s.mascotHeight
      }
      let origin =
        s.mascotPosition.flatMap { $0.count == 2 ? NSPoint(x: $0[0], y: $0[1]) : nil }
        ?? NSPoint(x: visible.maxX - mascot.frame.width - 32, y: visible.minY + 40)
      let adjusted = clamp(origin, size: mascot.frame.size)
      if mascot.frame.origin != adjusted { mascot.setFrameOrigin(adjusted) }
      if s.mascotVisible {
        if !mascot.isVisible { mascot.orderFrontRegardless() }
      } else {
        mascot.orderOut(nil)
      }
    }
    if let panel = sessionsPanel {
      let origin =
        s.sessionsPosition.flatMap { $0.count == 2 ? NSPoint(x: $0[0], y: $0[1]) : nil }
        ?? NSPoint(
          x: visible.maxX - panel.frame.width - 30, y: visible.maxY - panel.frame.height - 40)
      let adjusted = clamp(origin, size: panel.frame.size)
      if panel.frame.origin != adjusted { panel.setFrameOrigin(adjusted) }
      panel.alphaValue = s.panelOpacity
      if controller.overlayRequested && !controller.mainVisible {
        if !panel.isVisible { panel.orderFrontRegardless() }
      } else {
        panel.orderOut(nil)
      }
    }
    if let panel = voicePanel {
      panel.setFrameOrigin(NSPoint(x: visible.midX - 240, y: visible.maxY - 110))
      panel.alphaValue = s.panelOpacity
      if controller.isListening || controller.isInterpreting || s.alwaysShowVoice {
        if !panel.isVisible { panel.orderFrontRegardless() }
      } else {
        panel.orderOut(nil)
      }
    }
    positionApplied = true
  }
  func windowWillClose(_ notification: Notification) {
    if notification.object as? NSWindow === settingsWindow {
      controller.mainVisible = false
      NSApp.setActivationPolicy(.accessory)
      sync()
    }
  }
  func windowDidMiniaturize(_ notification: Notification) {
    if notification.object as? NSWindow === settingsWindow {
      controller.mainVisible = false
      sync()
    }
  }
  func windowDidDeminiaturize(_ notification: Notification) {
    if notification.object as? NSWindow === settingsWindow {
      controller.mainVisible = true
      sync()
    }
  }
  func windowDidMove(_ notification: Notification) {
    guard !syncing, let window = notification.object as? NSWindow else { return }
    let position = [Double(window.frame.origin.x), Double(window.frame.origin.y)]
    if window === mascotPanel { controller.settings.mascotPosition = position }
    if window === sessionsPanel { controller.settings.sessionsPosition = position }
  }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    showSettings()
    return true
  }
  func applicationWillTerminate(_ notification: Notification) {
    shortcuts?.stop()
    controller?.shutdown()
  }
}
@MainActor final class SessionPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}
@MainActor final class MovableMascotPanel: NSPanel {
  var clicked: (() -> Void)?
  private var start: NSPoint?
  private var origin = NSPoint.zero
  private var moved = false
  override func sendEvent(_ event: NSEvent) {
    switch event.type {
    case .leftMouseDown:
      start = NSEvent.mouseLocation
      origin = frame.origin
      moved = false
    case .leftMouseDragged:
      if let start {
        let now = NSEvent.mouseLocation
        let dx = now.x - start.x
        let dy = now.y - start.y
        if abs(dx) + abs(dy) > 4 { moved = true }
        setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y + dy))
      }
    case .leftMouseUp:
      if start != nil && !moved { clicked?() }
      start = nil
    default: super.sendEvent(event)
    }
  }
}
struct SessionOverlay: View {
  @Bindable var controller: OrbitController
  var body: some View {
    VStack(spacing: 20) {
      HStack {
        Image(systemName: "line.3.horizontal")
        Text("SESSIONI").font(.system(size: 15, weight: .black, design: .rounded)).tracking(1)
        Spacer()
        Button("Impostazioni") {
          controller.section = .sessions
          controller.openSettings?()
        }.controlSize(.small)
        Button {
          controller.overlayRequested = false
        } label: {
          Image(systemName: "xmark")
        }.buttonStyle(.plain)
      }
      ScrollView { SessionsView(controller: controller, compact: true) }.scrollIndicators(.hidden)
    }.padding(18).background(.black, in: RoundedRectangle(cornerRadius: 18)).foregroundStyle(.white)
      .tint(Palette.accent)
      .preferredColorScheme(.dark)
  }
}
struct VoiceOverlay: View {
  @Bindable var controller: OrbitController
  var body: some View {
    HStack(spacing: 16) {
      Image(
        systemName: controller.isListening
          ? "waveform" : controller.isInterpreting ? "sparkles" : "mic"
      ).font(.system(size: 23)).foregroundStyle(Palette.accent)
      VStack(alignment: .leading, spacing: 5) {
        Text(
          controller.isListening
            ? "TI STO ASCOLTANDO" : controller.isInterpreting ? "CI STO PENSANDO" : "HEY ORBIT"
        ).font(.system(size: 10, weight: .bold)).tracking(1.3)
        Text(
          controller.transcript.isEmpty
            ? "Dimmi su quale progetto vuoi lavorare" : controller.transcript
        ).font(.system(size: 13)).lineLimit(2).foregroundStyle(Palette.muted)
      }
      Spacer(minLength: 0)
      if controller.isListening {
        Button {
          controller.finishListening()
        } label: {
          Image(systemName: "arrow.up.circle.fill").font(.system(size: 23))
        }.buttonStyle(.plain).foregroundStyle(Palette.accent)
      }
      Button {
        if controller.isListening || controller.isInterpreting {
          controller.cancelListening()
        } else {
          controller.beginListening()
        }
      } label: {
        Image(
          systemName: controller.isListening || controller.isInterpreting ? "xmark" : "mic.fill")
      }.buttonStyle(.plain)
    }.padding(17).frame(width: 480, height: 80).background(
      Palette.background, in: RoundedRectangle(cornerRadius: 18)
    ).overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.1))).foregroundStyle(
      .white
    ).preferredColorScheme(.dark)
  }
}
