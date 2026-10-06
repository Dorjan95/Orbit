import Foundation

public struct DiskStore: Sendable {
  public let folder: URL
  public var stateURL: URL { folder.appendingPathComponent("state.json") }
  public init(folder: URL) { self.folder = folder }
  public static var standard: DiskStore {
    let root =
      ProcessInfo.processInfo.environment["ORBIT_DATA_HOME"].map { URL(fileURLWithPath: $0) }
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Orbit")
    return DiskStore(folder: root)
  }
  public func prepare() throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: folder.appendingPathComponent("logs"), withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
  }
  public func read() throws -> Snapshot {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(Snapshot.self, from: Data(contentsOf: stateURL))
  }
  public func write(_ state: Snapshot) throws {
    try prepare()
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    try encoder.encode(state).write(to: stateURL, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
  }
  public func credential() -> String? {
    let path = folder.appendingPathComponent("secrets/fish")
    return (try? String(contentsOf: path, encoding: .utf8))?.trimmingCharacters(
      in: .whitespacesAndNewlines)
  }
  public func setCredential(_ value: String?) throws {
    let dir = folder.appendingPathComponent("secrets")
    let file = dir.appendingPathComponent("fish")
    if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
      try Data(value.trimmingCharacters(in: .whitespacesAndNewlines).utf8).write(
        to: file, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    } else if FileManager.default.fileExists(atPath: file.path) {
      try FileManager.default.removeItem(at: file)
    }
  }
  public func logURL(_ job: UUID) -> URL {
    folder.appendingPathComponent("logs/\(job.uuidString).jsonl")
  }
  public func appendLog(_ line: String, job: UUID) {
    let file = logURL(job)
    if !FileManager.default.fileExists(atPath: file.path) {
      FileManager.default.createFile(
        atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
    }
    guard let handle = try? FileHandle(forWritingTo: file) else { return }
    defer { try? handle.close() }
    do {
      try handle.seekToEnd()
      try handle.write(contentsOf: Data((line + "\n").utf8))
    } catch {}
  }
}

/// Reads the old data schema as input. It does not link or execute the old program.
public enum ImportPreviousData {
  public static func load(from folder: URL) throws -> Snapshot {
    func object(_ name: String) -> Any? {
      guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)) else {
        return nil
      }
      return try? JSONSerialization.jsonObject(with: data)
    }
    guard let old = object("settings.json") as? [String: Any] else {
      throw CocoaError(.fileReadNoSuchFile)
    }
    var result = Snapshot()
    var s = result.settings
    func flag(_ key: String, _ fallback: Bool) -> Bool { old[key] as? Bool ?? fallback }
    func text(_ key: String, _ fallback: String = "") -> String { old[key] as? String ?? fallback }
    s.language = text("speechLocale", s.language)
    s.generalDirectory = text("generalWorkspace")
    s.newProjectsDirectory = text("projectsRoot", s.newProjectsDirectory)
    s.codexExecutable = text("codexPathOverride")
    s.claudeExecutable = text("claudePathOverride")
    s.interpreter = Agent(rawValue: text("orchestratorAgent")) ?? .codex
    for (key, modelKey, assistant) in [
      ("codexAssistantSelection", "codexOrchestratorModel", true),
      ("codexWorkerSelection", "codexModel", false),
    ] {
      let selection = old[key] as? [String: Any] ?? [:]
      let provider = Provider(rawValue: selection["provider"] as? String ?? "") ?? .openai
      let model =
        provider == .openai
        ? text(modelKey)
        : selection[provider == .ollama ? "ollamaModel" : "lmStudioModel"] as? String ?? ""
      let choice = ModelChoice(
        provider: provider, model: model,
        integrations: selection["includeIntegrations"] as? Bool ?? false)
      if assistant { s.assistant = choice } else { s.worker = choice }
    }
    s.handsFree = flag("handsFree", true)
    s.claps = flag("wakeOnClap", false)
    s.interruption = flag("echoCancellation", false)
    s.startup = flag("launchAtLogin", false)
    s.announcements = flag("speakProgress", true)
    s.summaries = flag("speakSummaries", true)
    s.openResults = flag("openResults", true)
    s.sound = flag("blipOnChordDown", true)
    s.focusSilence = flag("muteDuringFocus", true)
    s.alwaysShowVoice = flag("showIdlePill", false)
    s.panelOpacity = old["overlayOpacity"] as? Double ?? 1
    s.mascotVisible = flag("mascotEnabled", true)
    s.mascotMotion = flag("mascotAnimations", true)
    s.mascotCaption = flag("mascotShowStatus", true)
    s.mascotHeight = min(320, max(120, old["mascotSize"] as? Double ?? 200))
    s.mascotPosition = old["mascotOrigin"] as? [Double]
    s.sessionsPosition = old["overlayOrigin"] as? [Double]
    let mapping = [
      "idle": "ready", "speaking": "responding", "clarify": "question", "error": "problem",
    ]
    for (pose, clip) in old["mascotClipAssignments"] as? [String: String] ?? [:] {
      s.clips[mapping[pose] ?? pose] = clip
    }
    s.maximumJobs = min(6, max(1, old["maxConcurrentSessions"] as? Int ?? 6))
    s.fishVoiceID = text("fishVoiceID", s.fishVoiceID)
    s.fishVoiceTitle = text("fishVoiceName", s.fishVoiceTitle)
    s.fishModel = text("fishModel", s.fishModel)
    s.speechSpeed = old["speakingRate"] as? Double ?? 1
    s.systemFallback = flag("systemVoiceFallback", true)
    for (key, push) in [("pushToTalk", true), ("overlayToggle", false)] {
      if let hotkey = old[key] as? [String: Any], let code = hotkey["keyCode"] as? UInt32,
        let modifiers = hotkey["modifiers"] as? UInt32
      {
        if push {
          s.pushKey = code
          s.pushModifiers = modifiers
        } else {
          s.sessionsKey = code
          s.sessionsModifiers = modifiers
        }
      }
    }
    s.configured = false
    result.settings = s
    let projects = object("projects.json") as? [[String: Any]] ?? []
    for p in projects {
      guard let name = p["name"] as? String, let path = p["path"] as? String else { continue }
      let mode = p["permissionMode"] as? String ?? "acceptEdits"
      result.workspaces.append(
        Workspace(
          id: UUID(uuidString: p["id"] as? String ?? "") ?? UUID(), name: name, directory: path,
          aliases: p["aliases"] as? [String] ?? [],
          agent: Agent(rawValue: p["defaultAgent"] as? String ?? "") ?? .codex,
          access: mode == "bypassPermissions" ? .full : mode == "default" ? .readOnly : .project))
    }
    let iso = ISO8601DateFormatter()
    for p in object("sessions.json") as? [[String: Any]] ?? [] {
      guard let name = p["projectName"] as? String, let directory = p["projectPath"] as? String
      else { continue }
      var workspace =
        result.workspaces.first { $0.directory == directory }
        ?? Workspace(name: name, directory: directory)
      workspace.agent = Agent(rawValue: p["agent"] as? String ?? "") ?? workspace.agent
      var choice = s.worker
      if let b = p["codexBackend"] as? [String: Any] {
        choice = ModelChoice(
          provider: Provider(rawValue: b["provider"] as? String ?? "") ?? .openai,
          model: b["model"] as? String ?? "",
          integrations: b["includeIntegrations"] as? Bool ?? false)
      }
      var job = Job(workspace: workspace, request: p["task"] as? String ?? "", model: choice)
      job.id = UUID(uuidString: p["id"] as? String ?? "") ?? job.id
      let state = p["status"] as? String ?? "failed"
      job.status =
        ["done": JobStatus.completed, "needsInput": .waiting, "cancelled": .cancelled][state]
        ?? .failed
      job.activity =
        state == "running"
        ? "Sessione importata: riprendila dal pannello" : p["activity"] as? String ?? ""
      job.result = p["resultText"] as? String ?? ""
      job.resumeID = p["agentSessionID"] as? String
      job.hidden = p["dismissed"] as? Bool ?? false
      job.created = iso.date(from: p["startedAt"] as? String ?? "") ?? Date()
      job.finished = iso.date(from: p["finishedAt"] as? String ?? "")
      result.jobs.append(job)
    }
    if let entries = object("memory.json") as? [String] {
      result.memories = entries
    } else if let entries = object("memory.json") as? [[String: Any]] {
      result.memories = entries.compactMap { $0["text"] as? String }
    }
    for row in object("conversation.json") as? [[String: Any]] ?? [] {
      guard let heard = row["heard"] as? String else { continue }
      var exchange = Exchange(heard: heard, reply: row["said"] as? String ?? "")
      exchange.date = iso.date(from: row["at"] as? String ?? "") ?? Date()
      result.conversation.append(exchange)
    }
    return result
  }
}
