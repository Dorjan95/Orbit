import AppKit
import Foundation
import OrbitCore

@MainActor final class BrowserCoordinator {
  let folder: URL
  private struct Host {
    let process: ProcessStream
    let task: Task<Void, Never>
    let token: String
    var url: String?
    var failure: String?
  }
  private var hosts: [UUID: Host] = [:]
  init(folder: URL) { self.folder = folder }
  static var resources: URL {
    OrbitResources.bundle.url(forResource: "Resources", withExtension: nil)!.appendingPathComponent(
      "Browser")
  }
  func install() async throws {
    guard let npm = BrowserSupport.executable("npm") else {
      throw AgentError.execution(
        "Installa Node.js 18 o successivo, poi riprova la configurazione del browser.")
    }
    let runtime = BrowserSupport.runtime(in: folder)
    try FileManager.default.createDirectory(
      at: runtime, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    for name in ["package.json", "package-lock.json"] {
      try Data(contentsOf: Self.resources.appendingPathComponent(name)).write(
        to: runtime.appendingPathComponent(name), options: .atomic)
    }
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] =
      npm.deletingLastPathComponent().path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
    _ = try await ProcessStream().collect(
      Invocation(
        executable: npm,
        arguments: ["ci", "--ignore-scripts", "--no-audit", "--no-fund"], directory: runtime,
        environment: environment))
  }
  func connection(for id: UUID) async throws -> BrowserConnection {
    guard BrowserSupport.ready(in: folder), let node = BrowserSupport.executable("node") else {
      throw AgentError.execution(
        "Configura la navigazione web nella sezione Modelli. Servono Node.js e Google Chrome.")
    }
    if hosts[id]?.failure != nil && hosts[id]?.url == nil { close(id) }
    if hosts[id] == nil {
      let token = UUID().uuidString + UUID().uuidString
      let process = ProcessStream()
      let profile = folder.appendingPathComponent("browser/profiles/\(id)")
      let output = folder.appendingPathComponent("browser/output/\(id)")
      var environment = ProcessInfo.processInfo.environment
      environment["ORBIT_BROWSER_TOKEN"] = token
      let invocation = Invocation(
        executable: node,
        arguments: [
          Self.resources.appendingPathComponent("server.mjs").path,
          BrowserSupport.runtime(in: folder).path, profile.path, output.path,
        ], directory: folder, environment: environment)
      let task = Task { [weak self] in
        for await event in process.events(for: invocation) {
          guard let self else { return }
          switch event {
          case .started: break
          case .output(let line):
            if let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            {
              if let url = json["url"] as? String, URL(string: url)?.host == "127.0.0.1" {
                self.hosts[id]?.url = url
              }
              if let approval = json["approval"] as? [String: String] {
                self.review(approval, for: id)
              }
            }
          case .diagnostic(let text), .failed(let text):
            self.hosts[id]?.failure = String(text.prefix(500))
          case .finished:
            self.hosts[id]?.failure = "Il browser Orbit è stato chiuso."
            self.hosts[id]?.url = nil
          }
        }
      }
      hosts[id] = Host(process: process, task: task, token: token)
    }
    for _ in 0..<100 {
      try Task.checkCancellation()
      if let host = hosts[id], let url = host.url {
        return BrowserConnection(url: url, token: host.token)
      }
      if let failure = hosts[id]?.failure { throw AgentError.execution(failure) }
      try await Task.sleep(for: .milliseconds(100))
    }
    close(id)
    throw AgentError.execution(
      "Il browser Orbit non si è avviato. Controlla la configurazione in Modelli.")
  }
  func show(_ id: UUID) async throws {
    let connection = try await connection(for: id)
    let url = URL(string: connection.url)!.deletingLastPathComponent().appendingPathComponent(
      "open")
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
    let (_, response) = try await URLSession.shared.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
      throw AgentError.execution("Non riesco ad aprire la finestra del browser.")
    }
  }
  func close(_ id: UUID) {
    guard let host = hosts.removeValue(forKey: id) else { return }
    host.process.cancel()
    host.task.cancel()
  }
  private func review(_ approval: [String: String], for id: UUID) {
    guard let host = hosts[id], let address = host.url, let requestID = approval["id"] else {
      return
    }
    let alert = NSAlert()
    alert.messageText = "Conferma l’azione nel browser"
    alert.informativeText = [approval["description"], approval["url"], approval["preview"]]
      .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Annulla")
    alert.addButton(withTitle: "Conferma")
    NSApp.activate(ignoringOtherApps: true)
    let answer: @Sendable (NSApplication.ModalResponse) -> Void = { response in
      Task { @MainActor in
        var request = URLRequest(
          url: URL(string: address)!.deletingLastPathComponent()
            .appendingPathComponent("approve"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(host.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
          "id": requestID, "allowed": response == .alertSecondButtonReturn,
        ])
        _ = try? await URLSession.shared.data(for: request)
      }
    }
    if let window = NSApp.mainWindow {
      alert.beginSheetModal(for: window, completionHandler: answer)
    } else {
      answer(alert.runModal())
    }
  }
  func stop() { for id in Array(hosts.keys) { close(id) } }
}
