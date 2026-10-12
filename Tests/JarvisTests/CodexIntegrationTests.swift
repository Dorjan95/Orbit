import XCTest
@testable import Jarvis

final class CodexIntegrationTests: XCTestCase {
    func testPlainCodexStructuredResponse() {
        let json = #"{"action":"spawn","agent":"codex","project":null,"session_id":null,"task":"Controlla le note","speak":"Controllo le note.","remember":null,"forget":null,"coding":false}"#
        let action = Orchestrator.parse(resultJSON: json)
        XCTAssertEqual(action?.agent, .codex)
        XCTAssertEqual(action?.task, "Controlla le note")
        XCTAssertNil(Orchestrator.parse(resultJSON: #"{"speak":"Incomplete"}"#))
    }

    func testInterpreterPathUsesValidTOMLQuoting() {
        let args = Orchestrator.codexArgs(schemaPath: "/tmp/schema.json", outputPath: "/tmp/response.json",
                                          instructionsPath: "/tmp/with spaces/instructions.txt", model: "", prompt: "Ciao")
        XCTAssertTrue(args.contains(#"model_instructions_file="/tmp/with spaces/instructions.txt""#))
        XCTAssertTrue(args.contains("--ignore-user-config"))
        XCTAssertTrue(args.contains("read-only"))
        XCTAssertFalse(args.contains("--dangerously-bypass-approvals-and-sandbox"))
    }

    func testResumeKeepsSandboxOnParentCommand() async throws {
        guard let executable = CLILocator.find("codex") else { throw XCTSkip("Codex CLI is not installed") }
        let args = AgentRunner.arguments(agent: .codex, task: "Test", mode: .acceptEdits, resume: "test-session")
        let result = await CLILocator.run(executable, Array(args.dropLast()) + ["--help"], timeout: 10)
        XCTAssertEqual(result.code, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("SESSION_ID"))
        XCTAssertFalse(args.contains("--dangerously-bypass-approvals-and-sandbox"))
    }

    func testFastProcessDoesNotLoseOutputOrFinalPartialLine() async {
        let result = await CLILocator.run("/bin/zsh", ["-c", "for i in {1..12000}; do print -r -- $i; done; printf final"], timeout: 10)
        XCTAssertEqual(result.code, 0)
        let lines = result.stdout.split(separator: "\n")
        XCTAssertEqual(lines.count, 12001)
        XCTAssertEqual(lines.first, "1")
        XCTAssertEqual(lines.last, "final")
    }

    func testCodexResultOpensRelativeHTMLAndSkipsAlreadyOpened() {
        let changed = #"{"type":"item.completed","item":{"type":"file_change","status":"completed","changes":[{"path":"index.html","kind":"add"}]}}"#
        XCTAssertEqual(SessionResult.viewable(ndjson: changed, resultText: "Fatto", projectPath: "/tmp/demo")?.path, "/tmp/demo/index.html")
        let opened = #"{"type":"item.completed","item":{"type":"command_execution","command":"/bin/zsh -lc 'open index.html'","exit_code":0}}"#
        XCTAssertNil(SessionResult.viewable(ndjson: changed + "\n" + opened, resultText: "Fatto", projectPath: "/tmp/demo"))
        // Opening something in a previous turn must not suppress this turn's result.
        XCTAssertNotNil(SessionResult.viewable(ndjson: opened + "\n{\"type\":\"thread.started\"}\n" + changed,
                                               resultText: "Fatto", projectPath: "/tmp/demo"))
    }

    func testMissingSettingsUseCodexDefaults() throws {
        let settings = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
        XCTAssertEqual(settings.defaultAgent, .codex)
        XCTAssertEqual(settings.orchestratorAgent, .codex)
        XCTAssertEqual(settings.codexPermissionMode, .acceptEdits)
        XCTAssertNil(CLILocator.childEnvironment["CODEX_API_KEY"])
    }

    @MainActor
    func testGeneralWorkspaceUsesSelectedAgent() throws {
        let coordinator = Coordinator(enableServices: false)
        coordinator.settings.settings.defaultAgent = .codex
        coordinator.settings.settings.codexPermissionMode = .acceptEdits
        coordinator.settings.settings.projectsRoot = AppPaths.root.appendingPathComponent("projects").path
        coordinator.settings.settings.generalWorkspace = ""
        let project = try XCTUnwrap(coordinator.generalProject())
        XCTAssertEqual(project.defaultAgent, .codex)
        XCTAssertEqual(project.permissionMode, .acceptEdits)
    }

    @MainActor
    func testUnregisteredSessionCanBeContinuedAndCancelledQueueDoesNotRestart() async throws {
        let dir = AppPaths.root.appendingPathComponent("mock-cli")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let executable = dir.appendingPathComponent("codex")
        let script = "#!/bin/sh\nprintf '%s\\n' '{\"type\":\"thread.started\",\"thread_id\":\"mock-thread\"}'\n/bin/sleep 0.15\nprintf '%s\\n' '{\"type\":\"turn.completed\"}'\n"
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let coordinator = Coordinator(enableServices: false)
        coordinator.settings.settings.codexPathOverride = executable.path
        coordinator.settings.settings.speakSummaries = false
        coordinator.settings.settings.openResults = false
        let session = Session(id: "s_mock", projectName: "Unregistered workspace", projectPath: dir.path,
                              agent: .codex, task: "First", status: .done, resultText: "Old result")
        coordinator.sessions.insert(session)
        coordinator.followUp(session: session, task: "Continue")
        XCTAssertEqual(coordinator.sessions.session(session.id)?.status, .running)
        XCTAssertEqual(coordinator.sessions.session(session.id)?.resultText, "")
        let running = try XCTUnwrap(coordinator.sessions.session(session.id))
        coordinator.followUp(session: running, task: "Queued")
        coordinator.stop(sessionID: session.id)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(coordinator.sessions.session(session.id)?.status, .cancelled)
        XCTAssertEqual(coordinator.sessions.session(session.id)?.task, "Continue")
        XCTAssertNil(coordinator.sessions.session(session.id)?.pid)
    }

    /// Opt in explicitly: these tests use the user's ChatGPT allowance, never API keys.
    func testLiveCodexInterpreterAndSummary() async throws {
        guard ProcessInfo.processInfo.environment["JARVIS_LIVE_CODEX"] == "1" else {
            throw XCTSkip("Set JARVIS_LIVE_CODEX=1 to test the authenticated Codex CLI")
        }
        let executable = try XCTUnwrap(CLILocator.find("codex"))
        let orchestrator = Orchestrator(agent: .codex, executable: executable, codexModel: "gpt-6.1-sol")
        let action = await orchestrator.decide(transcript: "Nel progetto Demo crea una pagina HTML con scritto Ciao",
                                                projects: "- Demo · /tmp/demo · [] · codex", sessions: "- (none)",
                                                maxSessions: 2, runningCount: 0, context: nil)
        XCTAssertEqual(action.action, .spawn)
        XCTAssertEqual(action.agent, .codex)
        XCTAssertEqual(action.project, "Demo")
        XCTAssertTrue(action.task?.contains("Ciao") ?? false)
        let summary = await orchestrator.summarize(task: "Crea una pagina", project: "Demo", result: "Creata index.html con scritto Ciao",
                                                   isError: false, exitCode: 0)
        XCTAssertFalse(summary.isEmpty)
        XCTAssertNotEqual(summary, "Demo è pronto.")
    }

    func testLiveCodexCreatesFileAndResumesSession() async throws {
        guard ProcessInfo.processInfo.environment["JARVIS_LIVE_CODEX"] == "1" else {
            throw XCTSkip("Set JARVIS_LIVE_CODEX=1 to test actual work and resume")
        }
        let executable = try XCTUnwrap(CLILocator.find("codex"))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-work-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var first = AgentRunner.arguments(agent: .codex,
            task: "Crea soltanto prova.txt nella cartella corrente con il contenuto esatto PRIMA. Non aprire finestre. Non usare MCP.",
            mode: .acceptEdits, resume: nil)
        first.insert(contentsOf: ["-c", "model_reasoning_effort=\"low\""], at: 1)
        let result = await CLILocator.run(executable, first, cwd: dir.path, timeout: 90)
        XCTAssertEqual(result.code, 0, String(result.stderr.suffix(1500)) + String(result.stdout.suffix(4000)))
        let events = result.stdout.split(separator: "\n").flatMap { CodexStreamParser.parse(line: String($0)) }
        let sessionID = try XCTUnwrap(events.compactMap { event -> String? in
            if case .sessionID(let id) = event { return id }; return nil
        }.first)
        let file = dir.appendingPathComponent("prova.txt")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "PRIMA")
        var resumed = AgentRunner.arguments(agent: .codex,
            task: "Nello stesso file che hai appena creato sostituisci PRIMA con DOPO. Non creare altri file. Non aprire finestre. Non usare MCP.",
            mode: .acceptEdits, resume: sessionID)
        resumed.insert(contentsOf: ["-c", "model_reasoning_effort=\"low\""], at: 1)
        let followup = await CLILocator.run(executable, resumed, cwd: dir.path, timeout: 90)
        XCTAssertEqual(followup.code, 0, String(followup.stderr.suffix(1500)) + String(followup.stdout.suffix(4000)))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "DOPO")
    }
}
