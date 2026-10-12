import Foundation

// MARK: - Agents

enum AgentKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case claude, codex
    /// Decode old snapshots and journals without offering or launching the removed provider.
    case retiredDeepSeek = "deepseek"
    static let allCases: [Self] = [.claude, .codex]
    var isAvailable: Bool { Self.allCases.contains(self) }
    var id: String { rawValue }
    var displayName: String {
        switch self { case .claude: "Claude"; case .codex: "Codex"; case .retiredDeepSeek: "DeepSeek (storico)" }
    }
    static let interpreterCases: [Self] = [.claude, .codex]
    var cliName: String { isAvailable ? rawValue : "" }
}

enum PermissionMode: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Claude: `--permission-mode acceptEdits` · Codex: `-s workspace-write`
    case acceptEdits
    /// Claude: `--permission-mode bypassPermissions` · Codex: `--dangerously-bypass-approvals-and-sandbox`
    case bypassPermissions
    var id: String { rawValue }
    var displayName: String { self == .acceptEdits ? "Nel progetto" : "Accesso completo" }
}

// MARK: - Projects

struct Project: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    var path: String
    var aliases: [String] = []
    var defaultAgent: AgentKind = .codex
    var permissionMode: PermissionMode = .acceptEdits
    var verificationCommand: String? = nil

    var url: URL { URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
}

// Legacy project preferences migrate to a supported agent; remote sessions never do.
extension Project {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        path = try c.decode(String.self, forKey: .path)
        aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
        defaultAgent = try c.decodeIfPresent(AgentKind.self, forKey: .defaultAgent) ?? .codex
        permissionMode = try c.decodeIfPresent(PermissionMode.self, forKey: .permissionMode) ?? .acceptEdits
        verificationCommand = try c.decodeIfPresent(String.self, forKey: .verificationCommand)
        if !defaultAgent.isAvailable { defaultAgent = .codex; permissionMode = .acceptEdits }
    }
}

// MARK: - Sessions

enum SessionStatus: String, Codable, Sendable {
    case running, done, needsInput, failed, cancelled
    var isActive: Bool { self == .running }
    var isOngoing: Bool { self == .running || self == .needsInput }
    var label: String {
        switch self {
        case .running: "In corso"
        case .done: "Completata"
        case .needsInput: "Serve un input"
        case .failed: "Non riuscita"
        case .cancelled: "Annullata"
        }
    }
}

struct Session: Codable, Identifiable, Hashable, Sendable {
    var id: String                 // short id like "s_01"
    var projectName: String
    var projectPath: String
    var agent: AgentKind
    var task: String
    var status: SessionStatus = .running
    var activity: String = ""      // e.g. "Edit src/Hero.tsx"
    var startedAt: Date = Date()
    var finishedAt: Date? = nil
    var agentSessionID: String? = nil   // CLI-owned remote context
    var resultText: String = ""         // final agent result (truncated)
    var pid: Int32? = nil
    var dismissed: Bool = false
    var codexBackend: CodexBackend? = nil
    var executionConfiguration: AgentExecutionConfiguration? = nil
    var turns: [SessionTurn]? = nil
    var currentTurnID: UUID? = nil
    var approvals: [AgentApproval]? = nil
    var steering: SessionSteering? = nil
    var workflow: AgentWorkflow? = nil

    var usesRetiredAgent: Bool {
        !agent.isAvailable || executionConfiguration?.agent.isAvailable == false ||
            (turns ?? []).contains { !$0.configuration.agent.isAvailable }
    }

    var pendingApprovals: [AgentApproval] { (approvals ?? []).filter { $0.state == .pending } }

    var queuedTurns: [SessionTurn] { (turns ?? []).filter { $0.state == .queued } }
    var hasPendingWork: Bool { status.isOngoing || currentTurnID != nil || !queuedTurns.isEmpty }

    var elapsed: TimeInterval { (finishedAt ?? Date()).timeIntervalSince(startedAt) }
}

// MARK: - Orchestrator contract (§4.2)

enum OrchestratorActionKind: String, Codable, Sendable {
    case spawn, followup, steer, workflow, cancel, status, open, clarify, chitchat, create
}

struct OrchestratorAction: Codable, Sendable, Equatable {
    var action: OrchestratorActionKind
    var agent: AgentKind?
    var project: String?
    var sessionID: String?
    var task: String?
    var speak: String
    /// A durable fact/preference to store in long-term memory (any action may carry one). nil = nothing new.
    var remember: String? = nil
    /// A phrase identifying a memory to delete. nil = nothing to forget.
    var forget: String? = nil
    /// The task builds or changes software (sites, apps, scripts, fixes): it runs on the coding model (Opus 5.5).
    var coding: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case action, agent, project, task, speak, remember, forget, coding
        case sessionID = "session_id"
    }

    static let jsonSchema: String = """
    {"type":"object","additionalProperties":false,"properties":{"action":{"type":"string","enum":["spawn","followup","steer","workflow","cancel","status","open","clarify","chitchat","create"]},"agent":{"type":["string","null"],"enum":["claude","codex",null]},"project":{"type":["string","null"]},"session_id":{"type":["string","null"]},"task":{"type":["string","null"]},"speak":{"type":"string"},"remember":{"type":["string","null"]},"forget":{"type":["string","null"]},"coding":{"type":["boolean","null"]}},"required":["action","agent","project","session_id","task","speak","remember","forget","coding"]}
    """
}

// MARK: - Memory

/// One durable fact the user told Orbit ("I prefer Tailwind", "call me Albert", "always use Codex for the API project").
struct Memory: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var text: String
    var createdAt: Date = Date()
}

/// One exchange in the rolling conversation history (what was heard, what was said back).
struct ConversationTurn: Codable, Hashable, Sendable {
    var at: Date = Date()
    var heard: String
    var said: String
    var action: String
    var task: String? = nil
    var project: String? = nil
}

// MARK: - Settings

struct Hotkey: Codable, Hashable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32   // Carbon modifier mask (cmdKey | shiftKey | optionKey | controlKey)

    static let pushToTalk = Hotkey(keyCode: 49 /* kVK_Space */, modifiers: 0x0100 | 0x0200) // cmd | shift
    static let overlay = Hotkey(keyCode: 31 /* kVK_ANSI_O */, modifiers: 0x0100 | 0x0200)
}

private enum LegacyWorkflowKeys: String, CodingKey { case workflowDefinition }

struct Settings: Codable, Sendable {
    var pushToTalk: Hotkey = .pushToTalk
    var overlayToggle: Hotkey = .overlay
    var launchAtLogin: Bool = false
    var overlayOpacity: Double = 1.0
    var showIdlePill: Bool = false
    var mascotEnabled: Bool = true
    /// Artwork height in points; the status label sits below it.
    var mascotSize: Double = 200
    var mascotOrigin: CGPoint? = nil
    var mascotAnimations: Bool = true
    var mascotShowStatus: Bool = true
    var mascotClipAssignments: [String: String] = [:]
    var speakSummaries: Bool = true
    /// Short spoken progress lines while a session works, not only the summary at the end.
    var speakProgress: Bool = true
    /// Hands-free: say "Hey Orbit". The switch is also in the menu bar.
    var handsFree: Bool = true
    /// macOS echo cancellation on the hands-free mic, needed to talk over Orbit. Off = Orbit only listens between replies.
    var echoCancellation: Bool = false
    /// Hands-free also starts with a double clap (only while Orbit is idle).
    var wakeOnClap: Bool = true
    /// Folder where requests about no project start (mail, calendar, questions). Empty = `<projectsRoot>/general`.
    var generalWorkspace: String = ""
    /// Claude model for coding tasks (building or changing software). Other tasks use the CLI default.
    var codingModel: String = "claude-opus-5-5"
    /// Interpreter and summaries are independent of the agent selected for each project.
    var orchestratorAgent: AgentKind = .codex
    /// Empty uses the CLI default; routing runs with low reasoning in an isolated workspace.
    var codexOrchestratorModel: String = ""
    /// Empty honours the user's Codex configuration for work sessions.
    var codexModel: String = ""
    var codexAssistantSelection = CodexModelSelection()
    var codexWorkerSelection = CodexModelSelection()
    var workflowLibrary = WorkflowLibrary()
    var workflowDefinition: WorkflowDefinition {
        get { workflowLibrary.defaultDefinition }
        set { workflowLibrary.defaultDefinition = newValue }
    }
    var codexInteractiveControls: Bool = true
    var claudeInteractiveControls: Bool = true
    /// When a session built something to look at (an HTML page, a site on localhost), open it at the end.
    var openResults: Bool = true
    var muteDuringFocus: Bool = true
    var blipOnChordDown: Bool = true
    var defaultAgent: AgentKind = .codex
    /// Codex runs unattended with workspace restrictions by default; broader access is opt-in.
    var claudePermissionMode: PermissionMode = .bypassPermissions
    var codexPermissionMode: PermissionMode = .acceptEdits
    var maxConcurrentSessions: Int = 6
    /// "italiano": generic Italian male voice (not a celebrity clone), picked on 29/09/2026 from six Fish Pro samples.
    var fishVoiceID: String = "f888c2e0c08a4f16b00007c412797fbc"
    var fishVoiceName: String = "italiano (uomo)"
    /// Dictation locale for SFSpeechRecognizer; replies, summaries and voice search follow it.
    var speechLocale: String = "it-IT"
    /// "s2.1-pro" bills Fish API credit (USD); "s2.1-pro-free" is $0 and needs no API credit. "auto" tries pro, falls back to free on 402.
    var fishModel: String = "auto"
    var speakingRate: Double = 1.0
    var systemVoiceFallback: Bool = true
    var overlayOrigin: CGPoint? = nil
    var overlayVisible: Bool = true
    var onboardingComplete: Bool = false
    /// Where voice-created projects are made (§ create action).
    var projectsRoot: String = "~/Projects"
    var claudePathOverride: String? = nil
    var codexPathOverride: String? = nil

    func interactiveControls(for agent: AgentKind) -> Bool {
        switch agent {
        case .codex: codexInteractiveControls
        case .claude: claudeInteractiveControls
        case .retiredDeepSeek: false
        }
    }

    /// Missing keys fall back to the defaults above, so a settings.json written by an older build still loads.
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        pushToTalk = try c.decodeIfPresent(Hotkey.self, forKey: .pushToTalk) ?? d.pushToTalk
        overlayToggle = try c.decodeIfPresent(Hotkey.self, forKey: .overlayToggle) ?? d.overlayToggle
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        overlayOpacity = try c.decodeIfPresent(Double.self, forKey: .overlayOpacity) ?? d.overlayOpacity
        showIdlePill = try c.decodeIfPresent(Bool.self, forKey: .showIdlePill) ?? d.showIdlePill
        mascotEnabled = try c.decodeIfPresent(Bool.self, forKey: .mascotEnabled) ?? d.mascotEnabled
        mascotSize = min(320, max(120, try c.decodeIfPresent(Double.self, forKey: .mascotSize) ?? d.mascotSize))
        mascotOrigin = try c.decodeIfPresent(CGPoint.self, forKey: .mascotOrigin)
        mascotAnimations = try c.decodeIfPresent(Bool.self, forKey: .mascotAnimations) ?? d.mascotAnimations
        mascotShowStatus = try c.decodeIfPresent(Bool.self, forKey: .mascotShowStatus) ?? d.mascotShowStatus
        mascotClipAssignments = try c.decodeIfPresent([String: String].self, forKey: .mascotClipAssignments) ?? d.mascotClipAssignments
        // The new Meshy download replaces the step/sit clip and removes boxing.
        // Keep equivalent choices; removed clips fall back to the state's default.
        mascotClipAssignments = mascotClipAssignments.mapValues {
            $0 == "Step_to_Sit_Transition" ? OrbitMeshyClip.sitTransition.rawValue : $0
        }.filter { $0.value == "standing" || OrbitMeshyClip(rawValue: $0.value) != nil }
        speakSummaries = try c.decodeIfPresent(Bool.self, forKey: .speakSummaries) ?? d.speakSummaries
        speakProgress = try c.decodeIfPresent(Bool.self, forKey: .speakProgress) ?? d.speakProgress
        handsFree = try c.decodeIfPresent(Bool.self, forKey: .handsFree) ?? d.handsFree
        echoCancellation = try c.decodeIfPresent(Bool.self, forKey: .echoCancellation) ?? d.echoCancellation
        wakeOnClap = try c.decodeIfPresent(Bool.self, forKey: .wakeOnClap) ?? d.wakeOnClap
        generalWorkspace = try c.decodeIfPresent(String.self, forKey: .generalWorkspace) ?? d.generalWorkspace
        codingModel = try c.decodeIfPresent(String.self, forKey: .codingModel) ?? d.codingModel
        orchestratorAgent = try c.decodeIfPresent(AgentKind.self, forKey: .orchestratorAgent) ?? d.orchestratorAgent
        if !AgentKind.interpreterCases.contains(orchestratorAgent) { orchestratorAgent = d.orchestratorAgent }
        codexOrchestratorModel = try c.decodeIfPresent(String.self, forKey: .codexOrchestratorModel) ?? d.codexOrchestratorModel
        codexModel = try c.decodeIfPresent(String.self, forKey: .codexModel) ?? d.codexModel
        codexAssistantSelection = try c.decodeIfPresent(CodexModelSelection.self, forKey: .codexAssistantSelection) ?? d.codexAssistantSelection
        codexWorkerSelection = try c.decodeIfPresent(CodexModelSelection.self, forKey: .codexWorkerSelection) ?? d.codexWorkerSelection
        let legacy = try decoder.container(keyedBy: LegacyWorkflowKeys.self)
        workflowLibrary = try c.decodeIfPresent(WorkflowLibrary.self, forKey: .workflowLibrary)
            ?? WorkflowLibrary(definition: legacy.decodeIfPresent(WorkflowDefinition.self, forKey: .workflowDefinition) ?? .standard)
        codexInteractiveControls = try c.decodeIfPresent(Bool.self, forKey: .codexInteractiveControls) ?? d.codexInteractiveControls
        claudeInteractiveControls = try c.decodeIfPresent(Bool.self, forKey: .claudeInteractiveControls) ?? d.claudeInteractiveControls
        openResults = try c.decodeIfPresent(Bool.self, forKey: .openResults) ?? d.openResults
        muteDuringFocus = try c.decodeIfPresent(Bool.self, forKey: .muteDuringFocus) ?? d.muteDuringFocus
        blipOnChordDown = try c.decodeIfPresent(Bool.self, forKey: .blipOnChordDown) ?? d.blipOnChordDown
        defaultAgent = try c.decodeIfPresent(AgentKind.self, forKey: .defaultAgent) ?? d.defaultAgent
        if !defaultAgent.isAvailable { defaultAgent = d.defaultAgent }
        claudePermissionMode = try c.decodeIfPresent(PermissionMode.self, forKey: .claudePermissionMode) ?? d.claudePermissionMode
        codexPermissionMode = try c.decodeIfPresent(PermissionMode.self, forKey: .codexPermissionMode) ?? d.codexPermissionMode
        maxConcurrentSessions = try c.decodeIfPresent(Int.self, forKey: .maxConcurrentSessions) ?? d.maxConcurrentSessions
        fishVoiceID = try c.decodeIfPresent(String.self, forKey: .fishVoiceID) ?? d.fishVoiceID
        fishVoiceName = try c.decodeIfPresent(String.self, forKey: .fishVoiceName) ?? d.fishVoiceName
        speechLocale = try c.decodeIfPresent(String.self, forKey: .speechLocale) ?? d.speechLocale
        fishModel = try c.decodeIfPresent(String.self, forKey: .fishModel) ?? d.fishModel
        speakingRate = try c.decodeIfPresent(Double.self, forKey: .speakingRate) ?? d.speakingRate
        systemVoiceFallback = try c.decodeIfPresent(Bool.self, forKey: .systemVoiceFallback) ?? d.systemVoiceFallback
        overlayOrigin = try c.decodeIfPresent(CGPoint.self, forKey: .overlayOrigin)
        overlayVisible = try c.decodeIfPresent(Bool.self, forKey: .overlayVisible) ?? d.overlayVisible
        onboardingComplete = try c.decodeIfPresent(Bool.self, forKey: .onboardingComplete) ?? d.onboardingComplete
        projectsRoot = try c.decodeIfPresent(String.self, forKey: .projectsRoot) ?? d.projectsRoot
        claudePathOverride = try c.decodeIfPresent(String.self, forKey: .claudePathOverride)
        codexPathOverride = try c.decodeIfPresent(String.self, forKey: .codexPathOverride)
    }

    var assistantBackend: CodexBackend { codexAssistantSelection.backend(cloudModel: codexOrchestratorModel) }
    var workerBackend: CodexBackend { codexWorkerSelection.backend(cloudModel: codexModel) }

    func permissionMode(for agent: AgentKind) -> PermissionMode {
        switch agent { case .claude: claudePermissionMode; case .codex: codexPermissionMode; case .retiredDeepSeek: .acceptEdits }
    }
    var defaultPermissionMode: PermissionMode { permissionMode(for: defaultAgent) }

    var isItalian: Bool { speechLocale.hasPrefix("it") }
    /// Language name handed to the orchestrator for everything it says out loud.
    var replyLanguage: String { isItalian ? "Italian" : "English" }
    /// Two-letter code for Fish Audio's voice search.
    var voiceLanguageCode: String { String(speechLocale.prefix(2)) }
}
