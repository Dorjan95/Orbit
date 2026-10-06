import AppKit
import OrbitCore
import SwiftUI

extension OrbitDelegate {
  func renderDocumentation() {
    let args = ProcessInfo.processInfo.arguments
    let destination = args.drop(while: { $0 != "--render-docs" }).dropFirst().first ?? "docs/images"
    let output = URL(fileURLWithPath: destination)
    try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
      "orbit-docs-\(UUID())")
    defer { try? FileManager.default.removeItem(at: temporary) }
    let controller = OrbitController(disk: DiskStore(folder: temporary))
    controller.snapshot = Snapshot()
    controller.settings.configured = true
    controller.settings.handsFree = false
    controller.migrationNotice = nil
    let examples = [
      Workspace(name: "CantiereApp", directory: "/Projects/CantiereApp", aliases: ["il cantiere"]),
      Workspace(name: "EnvHalo", directory: "/Projects/EnvHalo", aliases: ["l’ambiente"]),
      Workspace(name: "Portfolio", directory: "/Projects/Portfolio", aliases: ["il sito"]),
    ]
    controller.snapshot.workspaces = examples
    var a = Job(
      workspace: examples[0],
      request: "Avvia CantiereApp in locale e verifica che portale e API siano raggiungibili.",
      model: ModelChoice())
    a.status = .completed
    a.result = "Portale e API verificati. L’applicazione è pronta per il test in locale."
    a.finished = Date()
    var b = Job(
      workspace: examples[1],
      request: "Controlla il flusso di onboarding e proponi miglioramenti per il primo avvio.",
      model: ModelChoice(provider: .ollama, model: "gpt-oss:20b"))
    b.activity = "Verifica dei componenti dell’onboarding"
    controller.snapshot.jobs = [b, a]
    controller.snapshot.memories = [
      "Preferisco risposte in italiano.",
      "Prima di una modifica, leggi le istruzioni della repository.",
    ]
    let view = NSHostingView(rootView: OrbitSettingsView(controller: controller))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1020, height: 850), styleMask: .borderless,
      backing: .buffered, defer: false)
    window.contentView = view
    view.frame = NSRect(x: 0, y: 0, width: 1020, height: 850)
    for (section, name) in [
      (Section.general, "orbit-general.png"), (.projects, "orbit-projects.png"),
      (.sessions, "orbit-sessions.png"),
    ] {
      controller.section = section
      view.layoutSubtreeIfNeeded()
      RunLoop.main.run(until: Date().addingTimeInterval(0.3))
      view.layoutSubtreeIfNeeded()
      if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let data = bitmap.representation(using: .png, properties: [:]) {
          try? data.write(to: output.appendingPathComponent(name))
          print("Rendered \(name)")
        }
      }
    }
  }
}
