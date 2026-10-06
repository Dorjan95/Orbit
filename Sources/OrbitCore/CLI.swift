import Foundation

public enum Executables {
  public static func locate(_ agent: Agent, override: String = "") -> URL? {
    let name = agent.rawValue
    var candidates = override.isEmpty ? [] : [(override as NSString).expandingTildeInPath]
    let search = ProcessInfo.processInfo.environment["PATH"] ?? ""
    candidates += search.split(separator: ":").map { "\($0)/\(name)" }
    candidates += [
      "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)",
      "\(NSHomeDirectory())/.local/bin/\(name)", "\(NSHomeDirectory())/.npm-global/bin/\(name)",
    ]
    if agent == .codex {
      for app in ["/Applications/Codex.app", "/Applications/ChatGPT.app"] {
        candidates += [
          app + "/Contents/Resources/codex",
          app + "/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
        ]
      }
    }
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map {
      URL(fileURLWithPath: $0)
    }
  }
}
public enum AgentCLI {
  public static func worker(
    _ job: Job, settings: Settings, prompt: String, resuming: Bool,
    browser: BrowserConnection? = nil
  ) throws
    -> Invocation
  {
    let override = job.agent == .codex ? settings.codexExecutable : settings.claudeExecutable
    guard let executable = Executables.locate(job.agent, override: override) else {
      throw AgentError.missing(job.agent)
    }
    let directory = URL(fileURLWithPath: (job.directory as NSString).expandingTildeInPath)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { throw AgentError.invalidDirectory }
    var args: [String]
    if job.agent == .codex {
      args = [
        "exec", "--json", "--color", "never", "--skip-git-repo-check", "--cd", directory.path,
      ]
      switch job.access {
      case .readOnly: args += ["--sandbox", "read-only"]
      case .project: args += ["--sandbox", "workspace-write"]
      case .full: args += ["--dangerously-bypass-approvals-and-sandbox"]
      }
      try addModel(job.model, to: &args)
      if let browser {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let encoded = String(decoding: try encoder.encode(browser.url), as: UTF8.self)
        let tools = String(decoding: try JSONEncoder().encode(BrowserSupport.tools), as: UTF8.self)
        args += [
          "-c", "mcp_servers.orbit_browser.url=\(encoded)",
          "-c", "mcp_servers.orbit_browser.bearer_token_env_var=\"ORBIT_BROWSER_TOKEN\"",
          "-c", "mcp_servers.orbit_browser.enabled=true",
          "-c", "mcp_servers.orbit_browser.required=true",
          "-c", "mcp_servers.orbit_browser.default_tools_approval_mode=\"approve\"",
          "-c", "mcp_servers.orbit_browser.enabled_tools=\(tools)",
          "-c", "mcp_servers.orbit_browser.startup_timeout_sec=30",
          "-c", "mcp_servers.orbit_browser.tool_timeout_sec=120",
        ]
      }
      if resuming, let id = job.resumeID { args += ["resume", id, "-"] } else { args += ["-"] }
    } else {
      args = ["--print", "--verbose", "--output-format", "stream-json"]
      switch job.access {
      case .readOnly: args += ["--permission-mode", "plan"]
      case .project: args += ["--permission-mode", "acceptEdits"]
      case .full: args += ["--dangerously-skip-permissions"]
      }
      if resuming, let id = job.resumeID { args += ["--resume", id] }
    }
    var environment: [String: String]? = nil
    if job.agent == .codex, let browser {
      environment = ProcessInfo.processInfo.environment
      environment?["ORBIT_BROWSER_TOKEN"] = browser.token
    }
    return Invocation(
      executable: executable, arguments: args, directory: directory, input: prompt,
      environment: environment)
  }
  public static func interactive(_ job: Job, settings: Settings) throws -> Invocation {
    let override = job.agent == .codex ? settings.codexExecutable : settings.claudeExecutable
    guard let executable = Executables.locate(job.agent, override: override) else {
      throw AgentError.missing(job.agent)
    }
    let directory = URL(fileURLWithPath: (job.directory as NSString).expandingTildeInPath)
    var args: [String] = []
    if job.agent == .codex {
      args = ["--cd", directory.path]
      try addModel(job.model, to: &args, isolated: true)
      switch job.access {
      case .readOnly: args += ["--sandbox", "read-only"]
      case .project: args += ["--sandbox", "workspace-write"]
      case .full: args += ["--dangerously-bypass-approvals-and-sandbox"]
      }
      if let id = job.resumeID { args += ["resume", id] }
    } else {
      switch job.access {
      case .readOnly: args += ["--permission-mode", "plan"]
      case .project: args += ["--permission-mode", "acceptEdits"]
      case .full: args += ["--dangerously-skip-permissions"]
      }
      if let id = job.resumeID { args += ["--resume", id] }
    }
    return Invocation(executable: executable, arguments: args, directory: directory)
  }
  public static func interpreter(
    settings: Settings, directory: URL, schema: URL, output: URL, prompt: String
  ) throws -> Invocation {
    let agent = settings.interpreter
    guard
      let executable = Executables.locate(
        agent, override: agent == .codex ? settings.codexExecutable : settings.claudeExecutable)
    else { throw AgentError.missing(agent) }
    var args: [String]
    if agent == .codex {
      args = [
        "exec", "--ignore-user-config", "--ephemeral", "--sandbox", "read-only",
        "--skip-git-repo-check", "--color", "never", "--cd", directory.path,
        "-c", "features.shell_tool=false", "-c", "features.apps=false", "-c",
        "features.plugins=false", "-c", "web_search=\"disabled\"", "--output-schema", schema.path,
        "--output-last-message", output.path,
      ]
      try addModel(settings.assistant, to: &args, isolated: true)
      args += ["-"]
    } else {
      args = [
        "--print", "--output-format", "json", "--no-session-persistence", "--tools", "",
        "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}", "--setting-sources", "",
        "--json-schema", try String(contentsOf: schema, encoding: .utf8),
      ]
    }
    return Invocation(executable: executable, arguments: args, directory: directory, input: prompt)
  }
  private static func addModel(
    _ model: ModelChoice, to args: inout [String], isolated: Bool = false
  ) throws {
    if !model.provider.local { args += ["-c", "model_provider=\"openai\""] }
    if model.provider.local {
      guard !model.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw AgentError.noLocalModel
      }
      args += ["--oss", "--local-provider", model.provider.rawValue]
      if !model.integrations && !isolated {
        args += [
          "--ignore-user-config", "-c", "features.apps=false", "-c", "features.plugins=false", "-c",
          "web_search=\"disabled\"",
        ]
      }
    }
    if !model.model.isEmpty { args += ["--model", model.model] }
  }
}
public enum AgentEvent: Equatable, Sendable {
  case session(String)
  case activity(String)
  case answer(String)
  case problem(String)
  case inputNeeded(String)
}
public enum EventDecoder {
  public static func decode(_ line: String, agent: Agent) -> [AgentEvent] {
    guard let bytes = line.data(using: .utf8),
      let json = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]
    else { return [] }
    let type = json["type"] as? String ?? ""
    if agent == .codex {
      if type == "thread.started", let id = json["thread_id"] as? String { return [.session(id)] }
      if type == "error" || type == "turn.failed" {
        let error = json["error"] as? [String: Any]
        return [
          .problem(
            error?["message"] as? String ?? json["message"] as? String ?? "Errore dell’agente")
        ]
      }
      guard let item = json["item"] as? [String: Any] else { return [] }
      let itemType = item["type"] as? String ?? ""
      let text = item["text"] as? String ?? ""
      if itemType == "agent_message", type == "item.completed" { return [.answer(text)] }
      if itemType == "reasoning", !text.isEmpty { return [.activity(text)] }
      if itemType == "command_execution" {
        return [
          .activity(
            (type == "item.completed" ? "Eseguito: " : "Esecuzione: ")
              + (item["command"] as? String ?? "comando"))
        ]
      }
      if itemType == "file_change" { return [.activity("Aggiornamento dei file del progetto")] }
      if itemType == "mcp_tool_call" {
        return [.activity("Strumento: " + (item["tool"] as? String ?? "MCP"))]
      }
    } else {
      if let id = json["session_id"] as? String, type == "system",
        json["subtype"] as? String == "init"
      {
        return [.session(id)]
      }
      if type == "assistant", let message = json["message"] as? [String: Any],
        let content = message["content"] as? [[String: Any]]
      {
        return content.compactMap { block in
          if block["type"] as? String == "text", let text = block["text"] as? String {
            return .answer(text)
          }
          if block["type"] as? String == "tool_use" {
            return .activity("Strumento: " + (block["name"] as? String ?? "azione"))
          }
          return nil
        }
      }
      if type == "result" {
        let text = json["result"] as? String ?? ""
        if json["is_error"] as? Bool == true { return [.problem(text)] }
        if let denials = json["permission_denials"] as? [Any], !denials.isEmpty {
          return [
            .inputNeeded(
              text.isEmpty
                ? "L’agente richiede un’autorizzazione. Apri il terminale per proseguire." : text)
          ]
        }
        return text.isEmpty ? [] : [.answer(text)]
      }
    }
    return []
  }
}
