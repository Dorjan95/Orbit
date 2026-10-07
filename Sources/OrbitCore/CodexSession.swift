import Foundation

public enum CodexSignal: Sendable {
  case session(String)
  case activity(String)
  case answer(String)
  case diagnostic(String)
  case request(AgentPrompt)
  case resolved(JSONValue)
  case integrations([ToolIntegration])
  case finished(String?)
}
/// One app-server connection per active Orbit turn. Resume IDs keep Codex history across connections.
@MainActor public final class CodexSession {
  private let process: ProcessStream
  private var threadID: String?
  private var turnID: String?
  private var expected: Int = 0
  private var stage = "avvio"
  private var ended = false
  private var waiting: [JSONValue: AgentPrompt] = [:]
  private var previews: [String: String] = [:]
  private var integrations: [ToolIntegration] = []
  private var watchdog: Task<Void, Never>?
  private var output: AsyncStream<CodexSignal>.Continuation?
  private var reader: Task<Void, Never>?
  public init(process: ProcessStream = ProcessStream()) { self.process = process }
  public func events(invocation: Invocation, job: Job, prompt: String, inspectOnly: Bool = false)
    -> AsyncStream<CodexSignal>
  {
    AsyncStream { continuation in
      output = continuation
      reader = Task { [self] in
        defer {
          watchdog?.cancel()
          continuation.finish()
          waiting.removeAll()
        }
        for await event in process.events(for: invocation, interactive: true) {
          do {
            switch event {
            case .started:
              try await request(
                1, "initialize",
                [
                  "clientInfo": ["name": "orbit", "title": "Orbit", "version": "1.2.0"],
                  "capabilities": [
                    "experimentalApi": true, "mcpServerOpenaiFormElicitation": true,
                  ],
                ])
            case .output(let line):
              guard let message = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
              else { continue }
              try await receive(message, job: job, prompt: prompt, inspectOnly: inspectOnly)
            case .diagnostic(let line): if !ended { continuation.yield(.diagnostic(line)) }
            case .failed(let error): finish(error)
            case .finished(let code):
              if !ended {
                finish(
                  "Il collegamento a Codex è terminato (\(code)). Verifica il CLI e l’account in Modelli, poi riprendi la sessione."
                )
              }
            }
          } catch { finish(error.localizedDescription) }
        }
      }
    }
  }
  private func write(_ value: JSONValue) async throws { try await process.send(value.json) }
  private func request(_ id: Int, _ method: String, _ params: JSONValue) async throws {
    expected = id
    stage = method
    armWatchdog()
    try await write(["id": .number(Double(id)), "method": .string(method), "params": params])
  }
  private func armWatchdog() {
    watchdog?.cancel()
    let method = stage
    watchdog = Task { [weak self] in
      try? await Task.sleep(for: .seconds(90))
      guard !Task.isCancelled else { return }
      self?.finish(
        "Codex non risponde durante \(method). Verifica il CLI e le connessioni MCP, poi riprova.")
    }
  }
  private func finish(_ error: String?) {
    guard !ended else { return }
    ended = true
    watchdog?.cancel()
    waiting.removeAll()
    output?.yield(.finished(error))
    if error == nil {
      process.closeInput()
      // Reap a server that does not exit on EOF; no connection survives a completed turn.
      DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [process] in process.cancel() }
    } else {
      process.cancel()
    }
  }
  public func respond(
    _ id: JSONValue, accept: Bool, answers: [String: String] = [:], form: JSONValue = [:]
  ) async throws {
    guard !ended, let pending = waiting[id], pending.params["threadId"].string == threadID,
      pending.params["turnId"] == .null || pending.params["turnId"].string == turnID
    else {
      throw AgentError.execution(
        "Questa richiesta non è più attiva. Nessuna autorizzazione è stata inviata.")
    }
    let result = try pending.response(accept: accept, answers: answers, form: form)
    try await write(["id": id, "result": result])
    waiting[id] = nil
    if waiting.isEmpty, expected != 0 { armWatchdog() }
    output?.yield(.resolved(id))
  }
  public func cancel() {
    ended = true
    watchdog?.cancel()
    waiting.removeAll()
    // Terminating only this connection cancels its running turn and any unresolved approvals.
    process.cancel()
  }
  private func receive(_ message: JSONValue, job: Job, prompt: String, inspectOnly: Bool)
    async throws
  {
    guard !ended else { return }
    if let method = message["method"].string {
      let p = message["params"]
      if message["id"] != .null {
        let id = message["id"]
        let supported = [
          "item/commandExecution/requestApproval", "item/fileChange/requestApproval",
          "item/permissions/requestApproval", "item/tool/requestUserInput",
          "mcpServer/elicitation/request",
        ]
        guard supported.contains(method) else {
          try await write([
            "id": id,
            "error": [
              "code": -32601, "message": .string("Orbit non supporta questa richiesta: \(method)"),
            ],
          ])
          throw AgentError.execution(
            "Codex richiede \(method), non supportato da questa versione di Orbit. Apri la sessione nel terminale per proseguire."
          )
        }
        let ask = AgentPrompt(
          id: id, method: method, params: p, filePreview: previews[p["itemId"].string ?? ""] ?? "")
        guard !inspectOnly, p["threadId"].string == threadID,
          p["turnId"] == .null || turnID == nil || p["turnId"].string == turnID
        else {
          try await write(["id": id, "result": try ask.response(accept: false)])
          if inspectOnly {
            output?.yield(
              .diagnostic(
                "\(ask.title): completa l’autenticazione dal CLI Codex e aggiorna le connessioni."))
          }
          return
        }
        if turnID == nil { turnID = p["turnId"].string }
        guard waiting[id] == nil else { return }
        if let result = try ask.automaticResponse(access: job.access) {
          try await write(["id": id, "result": result])
          output?.yield(.activity("Accesso completo · \(ask.title) autorizzata"))
          return
        }
        waiting[id] = ask
        watchdog?.cancel()
        output?.yield(.request(ask))
        return
      }
      if method == "thread/started", threadID == nil { threadID = p["thread"]["id"].string }
      guard p["threadId"] == .null || p["threadId"].string == threadID else { return }
      if let value = p["turnId"].string, let turnID, value != turnID { return }
      switch method {
      case "turn/started": turnID = p["turn"]["id"].string
      case "mcpServerStatus/updated":
        if let i = integrations.firstIndex(where: { $0.name == p["name"].string }) {
          integrations[i].status = p["status"].string ?? integrations[i].status
          integrations[i].error = p["error"].string
          output?.yield(.integrations(integrations))
        }
      case "serverRequest/resolved":
        let id = p["requestId"]
        waiting[id] = nil
        if waiting.isEmpty, expected != 0 { armWatchdog() }
        output?.yield(.resolved(id))
      case "item/started", "item/completed":
        let item = p["item"]
        switch item["type"].string {
        case "agentMessage":
          if method == "item/completed", let text = item["text"].string {
            output?.yield(.answer(text))
          }
        case "commandExecution":
          output?.yield(.activity("Esecuzione: " + (item["command"].string ?? "comando")))
        case "fileChange":
          previews[item["id"].string ?? ""] = item["changes"].array.map {
            ($0["path"].string ?? "File") + "\n" + ($0["diff"].string ?? "")
          }.joined(separator: "\n\n")
          output?.yield(.activity("Aggiornamento dei file del progetto"))
        case "mcpToolCall":
          output?.yield(
            .activity("MCP: \(item["server"].string ?? "") · \(item["tool"].string ?? "strumento")")
          )
        case "webSearch": output?.yield(.activity("Ricerca sul web"))
        case "reasoning": output?.yield(.activity("Codex sta ragionando"))
        default: break
        }
      case "turn/completed":
        let turn = p["turn"]
        guard turnID == nil || turn["id"].string == turnID else { return }
        finish(
          turn["status"].string == "completed"
            ? nil : turn["error"]["message"].string ?? "Il lavoro è stato interrotto da Codex.")
      case "error":
        let text = p["error"]["message"].string ?? p["message"].string ?? "Errore Codex"
        if p["willRetry"].bool == true { output?.yield(.activity(text)) } else { finish(text) }
      default: break
      }
      return
    }
    guard message["id"].number == Double(expected) else { return }
    watchdog?.cancel()
    if message["error"] != .null {
      throw AgentError.execution(
        message["error"]["message"].string ?? "Errore nel protocollo Codex")
    }
    let result = message["result"]
    switch expected {
    case 1:
      try await write(["method": "initialized", "params": [:]])
      var params: [String: JSONValue] = [
        "cwd": .string(invocationDirectory(job)),
        "modelProvider": .string(job.model.provider.rawValue), "approvalsReviewer": "user",
        "approvalPolicy": job.access == .full ? "never" : "on-request",
        "sandbox": .string(
          job.access == .readOnly
            ? "read-only" : job.access == .project ? "workspace-write" : "danger-full-access"),
      ]
      if !job.model.model.isEmpty { params["model"] = .string(job.model.model) }
      if inspectOnly { params["ephemeral"] = true }
      if let id = job.resumeID, !inspectOnly {
        params["threadId"] = .string(id)
        // Older local exec sessions live in the shared CLI history. Resume their path in the isolated home.
        if job.model.provider.local && !job.model.integrations,
          let path = CodexServer.legacyPath(id)
        {
          params["path"] = .string(path)
        }
      }
      try await request(
        2, job.resumeID == nil || inspectOnly ? "thread/start" : "thread/resume", .object(params))
    case 2:
      guard let id = result["thread"]["id"].string else {
        throw AgentError.execution("Codex non ha restituito un ID di sessione.")
      }
      threadID = id
      if !inspectOnly { output?.yield(.session(id)) }
      try await request(
        3, "mcpServerStatus/list",
        ["threadId": .string(id), "limit": 100, "detail": "toolsAndAuthOnly"])
    case 3:
      integrations += result["data"].array.map(ToolIntegration.init)
      if let cursor = result["nextCursor"].string {
        try await request(
          3, "mcpServerStatus/list",
          [
            "threadId": .string(threadID!), "limit": 100, "detail": "toolsAndAuthOnly",
            "cursor": .string(cursor),
          ])
      } else {
        output?.yield(.integrations(integrations))
        if inspectOnly {
          finish(nil)
        } else {
          try await request(
            4, "turn/start",
            ["threadId": .string(threadID!), "input": [["type": "text", "text": .string(prompt)]]])
        }
      }
    case 4:
      turnID = result["turn"]["id"].string ?? turnID
      expected = 0
    default: break
    }
  }
  private func invocationDirectory(_ job: Job) -> String {
    (job.directory as NSString).expandingTildeInPath
  }
}

public enum CodexServer {
  public static func invocation(
    _ job: Job, settings: Settings, folder: URL, browser: BrowserConnection? = nil
  ) throws -> Invocation {
    // Reuse validated executable, directory and the narrowly scoped Orbit browser configuration.
    let legacy = try AgentCLI.worker(
      job, settings: settings, prompt: "", resuming: false, browser: browser)
    var args = [
      "app-server", "--stdio", "-c",
      "model_provider=\(JSONValue.string(job.model.provider.rawValue).json)",
    ]
    if job.model.provider.local && !job.model.integrations {
      args += [
        "-c", "features.apps=false", "-c", "features.plugins=false", "-c",
        "web_search=\"disabled\"",
      ]
    }
    if let start = legacy.arguments.firstIndex(where: {
      $0.hasPrefix("mcp_servers.orbit_browser.url=")
    }) {
      args += Array(legacy.arguments[(start - 1)..<(legacy.arguments.count - 1)])
    }
    var env = legacy.environment ?? ProcessInfo.processInfo.environment
    if job.model.provider.local && !job.model.integrations {
      let home = folder.appendingPathComponent("codex-local/\(job.id.uuidString)")
      try FileManager.default.createDirectory(
        at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      env["CODEX_HOME"] = home.path
    }
    return Invocation(
      executable: legacy.executable, arguments: args, directory: legacy.directory, environment: env)
  }
  public static func legacyPath(_ id: String) -> String? {
    guard UUID(uuidString: id) != nil else { return nil }
    let home = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex"
    for dir in ["sessions", "archived_sessions"] {
      guard
        let files = FileManager.default.enumerator(
          at: URL(fileURLWithPath: home).appendingPathComponent(dir),
          includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
      else { continue }
      for case let url as URL in files where url.lastPathComponent.hasSuffix("-\(id).jsonl") {
        return url.path
      }
    }
    return nil
  }
}
