import Foundation

public enum Agent: String, Codable, CaseIterable, Sendable { case codex, claude }
public enum Provider: String, Codable, CaseIterable, Sendable {
  case openai, ollama, lmstudio
  public var title: String {
    switch self {
    case .openai: "OpenAI · ChatGPT"
    case .ollama: "Ollama · locale"
    case .lmstudio: "LM Studio · locale"
    }
  }
  public var local: Bool { self != .openai }
}
public enum SpeechProvider: String, Codable, CaseIterable, Sendable {
  case fish, system
  public var title: String { self == .system ? "Voce di sistema · Apple" : "Fish Audio" }
}
public enum Access: String, Codable, CaseIterable, Sendable {
  case readOnly, project, full
  public var title: String {
    switch self {
    case .readOnly: "Sola lettura"
    case .project: "Nel progetto"
    case .full: "Accesso completo"
    }
  }
}
public struct ModelChoice: Codable, Hashable, Sendable {
  public var provider: Provider = .openai
  public var model = ""
  public var integrations = false
  public init(provider: Provider = .openai, model: String = "", integrations: Bool = false) {
    self.provider = provider
    self.model = model
    self.integrations = integrations
  }
}
public struct Workspace: Codable, Identifiable, Hashable, Sendable {
  public var id: UUID
  public var name: String
  public var directory: String
  public var aliases: [String]
  public var agent: Agent
  public var access: Access
  public init(
    id: UUID = UUID(), name: String, directory: String, aliases: [String] = [],
    agent: Agent = .codex, access: Access = .project
  ) {
    self.id = id
    self.name = name
    self.directory = directory
    self.aliases = aliases
    self.agent = agent
    self.access = access
  }
  public var url: URL { URL(fileURLWithPath: (directory as NSString).expandingTildeInPath) }
}
public enum JobStatus: String, Codable, Sendable {
  case running, waiting, completed, failed, cancelled
  public var ongoing: Bool { self == .running || self == .waiting }
  public var title: String {
    switch self {
    case .running: "In corso"
    case .waiting: "Serve un input"
    case .completed: "Completata"
    case .failed: "Non riuscita"
    case .cancelled: "Annullata"
    }
  }
}
public struct Job: Codable, Identifiable, Sendable {
  public var id = UUID()
  public var workspaceID: UUID?
  public var workspaceName: String
  public var directory: String
  public var agent: Agent
  public var access: Access
  public var model: ModelChoice
  public var request: String
  public var status: JobStatus = .running
  public var activity = "Avvio dell’agente…"
  public var result = ""
  public var resumeID: String?
  public var created = Date()
  public var finished: Date?
  public var hidden = false
  public var queued: [String] = []
  public init(workspace: Workspace, request: String, model: ModelChoice) {
    workspaceID = workspace.id
    workspaceName = workspace.name
    directory = workspace.directory
    agent = workspace.agent
    access = workspace.access
    self.request = request
    self.model = model
  }
}
public enum MascotState: String, CaseIterable, Codable, Sendable {
  case ready, greeting, listening, thinking, responding, working, success, question, problem
  public var title: String {
    switch self {
    case .ready: "Riposo"
    case .greeting: "Saluto"
    case .listening: "Ascolto"
    case .thinking: "Ragionamento"
    case .responding: "Risposta"
    case .working: "Lavoro"
    case .success: "Successo"
    case .question: "Domanda"
    case .problem: "Problema"
    }
  }
  public var message: String {
    switch self {
    case .ready: "Cliccami per parlare"
    case .greeting: "Ciao! Sono pronto."
    case .listening: "Dimmi tutto, ti sto ascoltando"
    case .thinking: "Ci sto pensando…"
    case .responding: "Ecco cosa ho da dirti"
    case .working: "Mi metto al lavoro"
    case .success: "Fatto!"
    case .question: "Ho una domanda per te"
    case .problem: "Qualcosa non va"
    }
  }
  public var symbol: String? {
    switch self {
    case .responding: "text.bubble.fill"
    case .question: "questionmark.bubble.fill"
    case .problem: "exclamationmark.triangle.fill"
    default: nil
    }
  }
}
public struct Settings: Codable, Sendable {
  public var language = "it-IT"
  public var interpreter: Agent = .codex
  public var assistant = ModelChoice()
  public var worker = ModelChoice()
  public var maximumJobs = 6
  public var generalDirectory = ""
  public var newProjectsDirectory = "~/Projects"
  public var codexExecutable = ""
  public var claudeExecutable = ""
  public var handsFree = true
  public var claps = false
  public var interruption = false
  public var startup = false
  public var announcements = true
  public var summaries = true
  public var openResults = true
  public var focusSilence = true
  public var sound = true
  public var alwaysShowVoice = false
  public var panelOpacity = 1.0
  public var pushKey: UInt32 = 49
  public var pushModifiers: UInt32 = 768
  public var sessionsKey: UInt32 = 31
  public var sessionsModifiers: UInt32 = 768
  public var mascotVisible = true
  public var mascotHeight = 200.0
  public var mascotMotion = true
  public var mascotCaption = true
  public var mascotPosition: [Double]?
  public var sessionsPosition: [Double]?
  public var clips: [String: String] = [:]
  public var fishVoiceID = "f888c2e0c08a4f16b00007c412797fbc"
  public var fishVoiceTitle = "Italiano"
  public var fishModel = "auto"
  public var speechSpeed = 1.0
  public var systemFallback = true
  public var speechProvider: SpeechProvider = .fish
  public var systemVoiceID = ""
  public var configured = false
  public var browserEnabled = false
  public init() {}
  enum CodingKeys: String, CodingKey {
    case language, interpreter, assistant, worker, maximumJobs, generalDirectory,
      newProjectsDirectory, codexExecutable, claudeExecutable, handsFree, claps, interruption,
      startup, announcements, summaries, openResults, focusSilence, sound, alwaysShowVoice,
      panelOpacity, pushKey, pushModifiers, sessionsKey, sessionsModifiers, mascotVisible,
      mascotHeight, mascotMotion, mascotCaption, mascotPosition, sessionsPosition, clips,
      fishVoiceID, fishVoiceTitle, fishModel, speechSpeed, systemFallback, speechProvider,
      systemVoiceID, configured,
      browserEnabled
  }
  public init(from decoder: any Decoder) throws {
    self.init()
    let c = try decoder.container(keyedBy: CodingKeys.self)
    language = try c.decodeIfPresent(String.self, forKey: .language) ?? language
    interpreter = try c.decodeIfPresent(Agent.self, forKey: .interpreter) ?? interpreter
    assistant = try c.decodeIfPresent(ModelChoice.self, forKey: .assistant) ?? assistant
    worker = try c.decodeIfPresent(ModelChoice.self, forKey: .worker) ?? worker
    maximumJobs = try c.decodeIfPresent(Int.self, forKey: .maximumJobs) ?? maximumJobs
    generalDirectory =
      try c.decodeIfPresent(String.self, forKey: .generalDirectory) ?? generalDirectory
    newProjectsDirectory =
      try c.decodeIfPresent(String.self, forKey: .newProjectsDirectory) ?? newProjectsDirectory
    codexExecutable =
      try c.decodeIfPresent(String.self, forKey: .codexExecutable) ?? codexExecutable
    claudeExecutable =
      try c.decodeIfPresent(String.self, forKey: .claudeExecutable) ?? claudeExecutable
    handsFree = try c.decodeIfPresent(Bool.self, forKey: .handsFree) ?? handsFree
    claps = try c.decodeIfPresent(Bool.self, forKey: .claps) ?? claps
    interruption = try c.decodeIfPresent(Bool.self, forKey: .interruption) ?? interruption
    startup = try c.decodeIfPresent(Bool.self, forKey: .startup) ?? startup
    announcements = try c.decodeIfPresent(Bool.self, forKey: .announcements) ?? announcements
    summaries = try c.decodeIfPresent(Bool.self, forKey: .summaries) ?? summaries
    openResults = try c.decodeIfPresent(Bool.self, forKey: .openResults) ?? openResults
    focusSilence = try c.decodeIfPresent(Bool.self, forKey: .focusSilence) ?? focusSilence
    sound = try c.decodeIfPresent(Bool.self, forKey: .sound) ?? sound
    alwaysShowVoice = try c.decodeIfPresent(Bool.self, forKey: .alwaysShowVoice) ?? alwaysShowVoice
    panelOpacity = try c.decodeIfPresent(Double.self, forKey: .panelOpacity) ?? panelOpacity
    pushKey = try c.decodeIfPresent(UInt32.self, forKey: .pushKey) ?? pushKey
    pushModifiers = try c.decodeIfPresent(UInt32.self, forKey: .pushModifiers) ?? pushModifiers
    sessionsKey = try c.decodeIfPresent(UInt32.self, forKey: .sessionsKey) ?? sessionsKey
    sessionsModifiers =
      try c.decodeIfPresent(UInt32.self, forKey: .sessionsModifiers) ?? sessionsModifiers
    mascotVisible = try c.decodeIfPresent(Bool.self, forKey: .mascotVisible) ?? mascotVisible
    mascotHeight = try c.decodeIfPresent(Double.self, forKey: .mascotHeight) ?? mascotHeight
    mascotMotion = try c.decodeIfPresent(Bool.self, forKey: .mascotMotion) ?? mascotMotion
    mascotCaption = try c.decodeIfPresent(Bool.self, forKey: .mascotCaption) ?? mascotCaption
    mascotPosition = try c.decodeIfPresent([Double].self, forKey: .mascotPosition)
    sessionsPosition = try c.decodeIfPresent([Double].self, forKey: .sessionsPosition)
    clips = try c.decodeIfPresent([String: String].self, forKey: .clips) ?? clips
    fishVoiceID = try c.decodeIfPresent(String.self, forKey: .fishVoiceID) ?? fishVoiceID
    fishVoiceTitle = try c.decodeIfPresent(String.self, forKey: .fishVoiceTitle) ?? fishVoiceTitle
    fishModel = try c.decodeIfPresent(String.self, forKey: .fishModel) ?? fishModel
    speechSpeed = try c.decodeIfPresent(Double.self, forKey: .speechSpeed) ?? speechSpeed
    systemFallback = try c.decodeIfPresent(Bool.self, forKey: .systemFallback) ?? systemFallback
    speechProvider =
      try c.decodeIfPresent(SpeechProvider.self, forKey: .speechProvider) ?? speechProvider
    systemVoiceID = try c.decodeIfPresent(String.self, forKey: .systemVoiceID) ?? systemVoiceID
    configured = try c.decodeIfPresent(Bool.self, forKey: .configured) ?? configured
    browserEnabled = try c.decodeIfPresent(Bool.self, forKey: .browserEnabled) ?? browserEnabled
  }
}
public struct Exchange: Codable, Sendable {
  public var heard: String
  public var reply: String
  public var date = Date()
  public init(heard: String, reply: String) {
    self.heard = heard
    self.reply = reply
  }
}
public struct Snapshot: Codable, Sendable {
  public var version = 1
  public var settings = Settings()
  public var workspaces: [Workspace] = []
  public var jobs: [Job] = []
  public var memories: [String] = []
  public var conversation: [Exchange] = []
  public init() {}
}

public enum WakePhrase {
  public static func command(in text: String, atStartOnly: Bool = false) -> String? {
    let prefix = atStartOnly ? #"^\s*"# : ""
    guard
      let range = text.range(
        of: "(?i)" + prefix + #"\b(?:(?:hey|ehi|hei|ei)[\s,.!?;:]+)?[oòó]rbit\b[\s,.!?;:]*"#,
        options: .regularExpression)
    else { return nil }
    let remainder = String(text[range.upperBound...]).trimmingCharacters(
      in: .whitespacesAndNewlines)
    return remainder
  }
}

public enum ProjectMatch {
  public static func find(_ spoken: String, in projects: [Workspace]) -> [Workspace] {
    let words = spoken.folding(
      options: [.caseInsensitive, .diacriticInsensitive], locale: .current
    )
    .components(separatedBy: .alphanumerics.inverted).filter { !$0.isEmpty }
    let phrase = " " + words.joined(separator: " ") + " "
    return projects.filter { project in
      ([project.name] + project.aliases).contains { alias in
        let normal = alias.folding(
          options: [.caseInsensitive, .diacriticInsensitive], locale: .current
        )
        .components(separatedBy: .alphanumerics.inverted).filter { !$0.isEmpty }.joined(
          separator: " ")
        return !normal.isEmpty && phrase.contains(" " + normal + " ")
      }
    }
  }
}
