import Foundation

/// One headless CLI subprocess per session (§3.4). All agents share this runner;
/// only the argv and the line parser differ.
@MainActor
final class AgentRunner: AgentBackend {
    let sessionID: String
    let agent: AgentKind
    private var process: Subprocess?
    private var logHandle: FileHandle?
    private var lastText = ""
    private var stopPresses = 0
    private enum Delivery: Sendable { case events([AgentEvent]), exit(Int32) }
    let onEvent: @MainActor (AgentEvent) -> Void
    let onExit: @MainActor (Int32, String) -> Void   // exit code, last text seen

    init(sessionID: String, agent: AgentKind,
         onEvent: @escaping @MainActor (AgentEvent) -> Void,
         onExit: @escaping @MainActor (Int32, String) -> Void) {
        self.sessionID = sessionID; self.agent = agent; self.onEvent = onEvent; self.onExit = onExit
    }

    var pid: Int32? { process?.pid }
    var capabilities: AgentBackendCapabilities { CLIBackends.adapter(for: agent)?.capabilities ?? .unavailable }

    /// Sessions are headless and short-lived; anything meant to keep running must be detached.
    nonisolated static let sessionGuidance = """
    You are run headlessly by a voice assistant; nobody can answer questions, so make sensible decisions and finish the job.
    You have the user's connected tools (MCP servers: calendar, email, task managers, browsers…); use them for any
    "check / look up / find / send" request and report the answer in your final sentence(s) — that text is read aloud.
    If asked to run, serve, preview or open something: start servers DETACHED so they outlive this session
    (e.g. `nohup python3 -m http.server 6000 > /tmp/jarvis-serve.log 2>&1 &` or the project's own dev server with nohup/setsid),
    confirm the port is listening, and if asked to open it in the browser run `open http://localhost:<port>`.
    While you work, before each major step write one short sentence (max 15 words) in the same language as the task saying
    what you are about to do, the way a colleague would say it out loud ("Ora controllo i test della home"). These lines
    are read aloud as progress updates, so no code, paths longer than a file name, or markdown in them.
    When you built or changed something the user can look at (an HTML page, a site, an app, a document, an image),
    open it for them when you are done, without asking: `open <file>` for a file, or start the dev server and
    `open http://localhost:<port>` for a site. Skip it only for changes with nothing to look at, or if told not to.
    End with one short sentence stating what changed and any URL, written in the same language as the task (it is read aloud).
    """

    nonisolated static func arguments(agent: AgentKind, task: String, mode: PermissionMode, resume: String?, extraGuidance: String? = nil, model: String? = nil, backend: CodexBackend? = nil) -> [String] {
        let guidance = extraGuidance.map { sessionGuidance + "\n\n" + $0 } ?? sessionGuidance
        return CLIBackends.adapter(for: agent)?.arguments(task: task, mode: mode, resume: resume, guidance: guidance, model: model, backend: backend) ?? []
    }

    func start(_ request: AgentRunRequest) throws {
        guard request.configuration.agent == agent else { throw AgentBackendError.wrongAgent }
        try start(executable: request.executable, task: request.task, cwd: request.cwd,
                  mode: request.configuration.permissionMode, resume: request.resume, extraGuidance: request.guidance,
                  model: request.configuration.model, backend: request.configuration.codex, readOnly: request.configuration.readOnly == true)
    }

    func start(executable: String, task: String, cwd: String, mode: PermissionMode, resume: String?, extraGuidance: String? = nil, model: String? = nil, backend: CodexBackend? = nil, readOnly: Bool = false) throws {
        guard process == nil else { throw AgentBackendError.alreadyRunning }
        guard let adapter = CLIBackends.adapter(for: agent) else { throw AgentBackendError.removedAgent }
        var args = Self.arguments(agent: agent, task: task, mode: mode, resume: resume, extraGuidance: extraGuidance, model: model, backend: backend)
        if readOnly {
            switch agent {
            case .codex:
                // Review ignores user integrations and uses the CLI read-only sandbox.
                args.removeAll { $0 == "--ignore-user-config" }
                args.insert(contentsOf: ["--ignore-user-config", "-c", "mcp_servers={}", "-c", "features.apps=false", "-c", "features.plugins=false",
                    "-c", "web_search=\"disabled\""], at: 1)
                args.removeAll { $0 == "--dangerously-bypass-approvals-and-sandbox" }
                if let index = args.firstIndex(of: "-s") { args[index + 1] = "read-only" }
                else { args.insert(contentsOf: ["-s", "read-only", "-c", "approval_policy=\"never\""], at: args.firstIndex(of: "exec")! + 1) }
            case .claude:
                if let index = args.firstIndex(of: "--permission-mode") { args[index + 1] = "plan" }
                args.insert(contentsOf: ["--tools", "Read,Glob,Grep", "--allowedTools", "Read,Glob,Grep",
                    "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
                    "--settings", "{\"disableAllHooks\":true}"], at: 0)
            case .retiredDeepSeek: throw AgentBackendError.removedAgent
            }
        }
        let p = try Subprocess(executable: executable, arguments: args, cwd: cwd, environment: CLILocator.childEnvironment)
        let logURL = AppPaths.log(for: sessionID)
        if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
        logHandle = try? FileHandle(forWritingTo: logURL)
        logHandle?.seekToEndOfFile()
        let log = logHandle
        let (stream, continuation) = AsyncStream<Delivery>.makeStream()
        // One consumer preserves pipe order all the way to MainActor. Independent
        // Tasks per callback could finish a turn before its final result/remote ID.
        Task { @MainActor [weak self] in
            for await delivery in stream {
                guard let self else { return }
                switch delivery {
                case .events(let events):
                    for event in events {
                        if case .text(let text) = event { lastText = text }
                        if case .result(let text, _) = event, !text.isEmpty { lastText = text }
                        onEvent(event)
                    }
                case .exit(let code):
                    try? logHandle?.close()
                    onExit(code, lastText)
                }
            }
        }
        p.onLine = { line in
            log?.write(Data((line + "\n").utf8))
            let events = adapter.parse(line: line)
            guard !events.isEmpty else { return }
            continuation.yield(.events(events))
        }
        p.onStderr = { line in log?.write(Data(("[stderr] " + line + "\n").utf8)) }
        p.onExit = { code in
            continuation.yield(.exit(code))
            continuation.finish()
        }
        process = p
        p.start()
    }

    /// First press interrupts (SIGINT → SIGKILL after 3 s); second press kills immediately.
    func stop() {
        stopPresses += 1
        if stopPresses >= 2 { process?.kill() } else { process?.interrupt() }
    }

    func kill() { process?.kill() }
    var isRunning: Bool { process?.isRunning ?? false }
    func sendFollowup(_ task: String) throws { throw AgentBackendError.liveFollowupUnavailable }
    func cancel() { stop() }
    func close() { kill() }
}
