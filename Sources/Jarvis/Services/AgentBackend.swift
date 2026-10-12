import Foundation

/// Transport capabilities, independent of the model chosen by the interpreter.
struct AgentBackendCapabilities: Equatable, Sendable {
    let resume: Bool
    let liveFollowup: Bool
    let interactiveApprovals: Bool
    let steering: Bool

    static let headlessCLI = Self(resume: true, liveFollowup: false, interactiveApprovals: false, steering: false)
    static let unavailable = Self(resume: false, liveFollowup: false, interactiveApprovals: false, steering: false)
    static let nativeCLI = Self(resume: true, liveFollowup: false, interactiveApprovals: true, steering: true)
}

/// Frozen when a work request is accepted; later settings changes do not reroute it.
struct AgentExecutionConfiguration: Codable, Hashable, Sendable {
    var agent: AgentKind
    var permissionMode: PermissionMode
    var model: String?
    var codex: CodexBackend?
    var readOnly: Bool? = nil
    /// Missing in old sessions: retain the original one-shot CLI transport.
    var interactiveControls: Bool? = nil

    var supportsInteractiveControls: Bool {
        agent.isAvailable && readOnly != true && interactiveControls == true
    }
}

struct AgentRunRequest: Sendable {
    let executable: String
    let task: String
    let cwd: String
    let resume: String?
    let guidance: String?
    let configuration: AgentExecutionConfiguration
}

enum AgentBackendError: LocalizedError {
    case alreadyRunning, liveFollowupUnavailable, wrongAgent, expiredApproval, removedAgent
    var errorDescription: String? {
        switch self {
        case .alreadyRunning: "La sessione sta ancora lavorando."
        case .liveFollowupUnavailable: "Questo agente accetta i seguiti al termine del turno corrente."
        case .wrongAgent: "La configurazione appartiene a un altro agente."
        case .removedAgent: "Questo agente è stato rimosso. Avvia una nuova sessione con Codex o Claude."
        case .expiredApproval: "Questa richiesta di permesso non è più disponibile."
        }
    }
}

/// A runtime may outlive a turn. Coordinator owns queued input for transports without live delivery.
@MainActor
protocol AgentBackend: AnyObject {
    var capabilities: AgentBackendCapabilities { get }
    var pid: Int32? { get }
    var isRunning: Bool { get }
    var canSteer: Bool { get }
    var steeringSettled: Bool { get }
    func start(_ request: AgentRunRequest) throws
    func sendFollowup(_ task: String) throws
    func cancel()
    func close()
    func resolveApproval(_ id: UUID, optionID: String) throws
    func interruptForSteering() throws
}

extension AgentBackend {
    var canSteer: Bool { false }
    var steeringSettled: Bool { false }
    func interruptForSteering() throws { throw AgentBackendError.liveFollowupUnavailable }
    func resolveApproval(_ id: UUID, optionID: String) throws { throw AgentBackendError.expiredApproval }
}

/// CLI-specific commands and wire parsing stay outside session management.
protocol CLIBackendAdapter: Sendable {
    var agent: AgentKind { get }
    var capabilities: AgentBackendCapabilities { get }
    func arguments(task: String, mode: PermissionMode, resume: String?, guidance: String, model: String?, backend: CodexBackend?) -> [String]
    func parse(line: String) -> [AgentEvent]
}

struct ClaudeCLIAdapter: CLIBackendAdapter {
    let agent = AgentKind.claude
    let capabilities = AgentBackendCapabilities.headlessCLI

    func arguments(task: String, mode: PermissionMode, resume: String?, guidance: String, model: String?, backend: CodexBackend?) -> [String] {
        var args = ["-p", task, "--output-format", "stream-json", "--verbose", "--append-system-prompt", guidance,
                    "--permission-mode", mode == .bypassPermissions ? "bypassPermissions" : "acceptEdits"]
        if let resume { args += ["--resume", resume] }
        if let model, !model.isEmpty { args += ["--model", model] }
        return args
    }

    func parse(line: String) -> [AgentEvent] { ClaudeStreamParser.parse(line: line) }
}

struct CodexCLIAdapter: CLIBackendAdapter {
    let agent = AgentKind.codex
    let capabilities = AgentBackendCapabilities.headlessCLI

    func arguments(task: String, mode: PermissionMode, resume: String?, guidance: String, model: String?, backend: CodexBackend?) -> [String] {
        var args = ["exec", "-c", "features.shell_snapshot=false"]
        let selected = backend ?? CodexBackend(model: model ?? "")
        args += selected.arguments + selected.workerIsolationArguments
        if mode == .acceptEdits { args += ["-s", "workspace-write", "-c", "approval_policy=\"never\""] }
        // Sandbox options belong to exec, before its resume subcommand.
        if let resume { args += ["resume", resume] }
        args += ["--json", "--skip-git-repo-check"]
        if mode == .bypassPermissions { args += ["--dangerously-bypass-approvals-and-sandbox"] }
        return args + [task + "\n\n" + guidance]
    }

    func parse(line: String) -> [AgentEvent] { CodexStreamParser.parse(line: line) }
}

enum CLIBackends {
    static func adapter(for agent: AgentKind) -> (any CLIBackendAdapter)? {
        switch agent {
        case .claude: ClaudeCLIAdapter()
        case .codex: CodexCLIAdapter()
        case .retiredDeepSeek: nil
        }
    }
}
