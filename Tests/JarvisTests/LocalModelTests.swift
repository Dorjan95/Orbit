import XCTest
import SwiftUI
@testable import Jarvis

final class LocalModelTests: XCTestCase {
    func testSettingsMigrationKeepsExistingCloudModels() throws {
        let old = #"{"codexModel":"work-model","codexOrchestratorModel":"router-model"}"#
        let settings = try JSONDecoder().decode(Settings.self, from: Data(old.utf8))
        XCTAssertEqual(settings.workerBackend, CodexBackend(model: "work-model"))
        XCTAssertEqual(settings.assistantBackend, CodexBackend(model: "router-model"))
        XCTAssertTrue(settings.mascotEnabled)
        XCTAssertFalse(settings.showIdlePill)
        let restored = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(restored.workerBackend, settings.workerBackend)
    }

    func testProviderSwitchRetainsSeparateModelsAndIndependentRoles() {
        var settings = Settings()
        settings.codexAssistantSelection.provider = .ollama
        settings.codexAssistantSelection.localModel = "small-router:latest"
        settings.codexAssistantSelection.provider = .lmstudio
        settings.codexAssistantSelection.localModel = "studio-router"
        settings.codexAssistantSelection.provider = .ollama
        XCTAssertEqual(settings.assistantBackend.model, "small-router:latest")
        XCTAssertEqual(settings.workerBackend.provider, .openai)
    }

    func testLocalProviderAndModelArePassedBeforeResume() async throws {
        for provider in [CodexProvider.ollama, .lmstudio] {
            let backend = CodexBackend(provider: provider, model: " local-model ")
            let args = AgentRunner.arguments(agent: .codex, task: "Test", mode: .acceptEdits, resume: "abc", backend: backend)
            XCTAssertEqual(args[args.firstIndex(of: "--local-provider")! + 1], provider.rawValue)
            XCTAssertEqual(args[args.firstIndex(of: "--model")! + 1], "local-model")
            XCTAssertLessThan(args.firstIndex(of: "--oss")!, args.firstIndex(of: "resume")!)
            XCTAssertFalse(args.contains("--dangerously-bypass-approvals-and-sandbox"))
            if let cli = CLILocator.find("codex") {
                let result = await CLILocator.run(cli, Array(args.dropLast()) + ["--help"], timeout: 10)
                XCTAssertEqual(result.code, 0, result.stderr)
            }
        }
    }

    func testLocalWorkersUseProjectToolsAndOptionalIntegrations() throws {
        let local = CodexBackend(provider: .ollama, model: "test")
        let args = AgentRunner.arguments(agent: .codex, task: "Test", mode: .acceptEdits, resume: nil, backend: local)
        XCTAssertTrue(args.contains("--ignore-user-config"))
        XCTAssertTrue(args.contains("features.plugins=false"))
        XCTAssertTrue(args.contains("model_context_window=16384"))
        XCTAssertFalse(local.workerIsolationArguments.contains("features.shell_tool=false"))
        XCTAssertTrue(CodexBackend(provider: .ollama, model: "test", includeIntegrations: true).workerIsolationArguments.isEmpty)
        XCTAssertTrue(CodexBackend().workerIsolationArguments.isEmpty)
        let oldBackend = try JSONDecoder().decode(CodexBackend.self, from: Data(#"{"provider":"ollama","model":"test"}"#.utf8))
        XCTAssertEqual(oldBackend, local)
        let oldSelection = try JSONDecoder().decode(CodexModelSelection.self, from: Data(#"{"provider":"ollama","ollamaModel":"test","lmStudioModel":""}"#.utf8))
        XCTAssertEqual(oldSelection.backend(cloudModel: ""), local)
    }

    func testLocalInterpreterDoesNotInheritCloudReasoningOrUserConfiguration() {
        let args = Orchestrator.codexArgs(schemaPath: "/tmp/schema", outputPath: "/tmp/output", instructionsPath: "/tmp/instructions", model: "wrong-cloud-model", prompt: "Ciao", backend: CodexBackend(provider: .ollama, model: "local-model"))
        XCTAssertTrue(args.contains("--oss"))
        XCTAssertTrue(args.contains("--ignore-user-config"))
        XCTAssertTrue(args.contains("features.shell_tool=false"))
        XCTAssertFalse(args.contains("wrong-cloud-model"))
        XCTAssertFalse(args.contains(#"model_reasoning_effort="low""#))
    }

    func testDiscoveryDecodesBothProvidersAndRejectsInvalidResponses() throws {
        let ollama = #"{"models":[{"name":"b:latest"},{"name":"a:latest"},{"name":"b:latest"}]}"#
        XCTAssertEqual(try LocalModelService.parse(Data(ollama.utf8), provider: .ollama), ["a:latest", "b:latest"])
        let studio = #"{"data":[{"id":"studio-model"},{"id":""}]}"#
        XCTAssertEqual(try LocalModelService.parse(Data(studio.utf8), provider: .lmstudio), ["studio-model"])
        XCTAssertThrowsError(try LocalModelService.parse(Data("{}".utf8), provider: .ollama))
        XCTAssertThrowsError(try LocalModelService.parse(Data("not json".utf8), provider: .lmstudio))
    }

    @MainActor
    func testMissingLocalModelRefusesSpawnWithoutCreatingBrokenSession() {
        let coordinator = Coordinator(enableServices: false)
        coordinator.settings.settings.codexPathOverride = "/bin/echo"
        coordinator.settings.settings.codexWorkerSelection.provider = .ollama
        coordinator.settings.settings.codexWorkerSelection.ollamaModel = " "
        let before = coordinator.sessions.sessions.count
        XCTAssertFalse(coordinator.spawn(project: Project(name: "Test", path: AppPaths.root.path), agent: .codex, task: "Test"))
        XCTAssertEqual(coordinator.sessions.sessions.count, before)
        guard case .configuration = coordinator.lastSpawnFailure else { return XCTFail("Expected configuration error") }
    }

    @MainActor
    func testFollowupKeepsSessionBackendAfterGlobalSettingsChange() async throws {
        let dir = AppPaths.root.appendingPathComponent("backend-test")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let executable = dir.appendingPathComponent("codex")
        let capture = dir.appendingPathComponent("arguments.txt")
        let script = "#!/bin/sh\nprintf '%s\\n' \"$@\" > " + CodexBackend.shellQuote(capture.path) + "\nprintf '%s\\n' '{\"type\":\"thread.started\",\"thread_id\":\"test-thread\"}'\n/bin/sleep 0.1\n"
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let coordinator = Coordinator(enableServices: false)
        coordinator.settings.settings.codexPathOverride = executable.path
        coordinator.settings.settings.speakSummaries = false
        coordinator.settings.settings.openResults = false
        coordinator.settings.settings.codexWorkerSelection.provider = .lmstudio
        coordinator.settings.settings.codexWorkerSelection.lmStudioModel = "new-model"
        let original = CodexBackend(provider: .ollama, model: "original-model")
        let session = Session(id: "s_backend", projectName: "Test", projectPath: dir.path, agent: .codex, task: "First", status: .done, agentSessionID: "test-thread", codexBackend: original)
        coordinator.sessions.insert(session)
        coordinator.followUp(session: session, task: "Continue")
        for _ in 0..<150 {
            // followUp launches asynchronously; the initial .done status is not completion.
            if FileManager.default.fileExists(atPath: capture.path),
               coordinator.sessions.session(session.id)?.status != .running { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(coordinator.sessions.session(session.id)?.codexBackend, original)
        let args = try String(contentsOf: capture, encoding: .utf8)
        XCTAssertTrue(args.contains("ollama\n"))
        XCTAssertTrue(args.contains("original-model\n"))
        XCTAssertFalse(args.contains("new-model"))
    }

    func testResumeCommandQuotesUntrustedModelNames() {
        let command = CodexBackend(provider: .ollama, model: "model'$(touch nope)").resumeCommand(executable: "/path with spaces/codex", sessionID: "id")
        XCTAssertTrue(command.contains("'model'\\''$(touch nope)'"))
        XCTAssertTrue(command.hasPrefix("'/path with spaces/codex'"))
    }

    func testLiveLocalModelRoutesAndSummarizes() async throws {
        guard let model = ProcessInfo.processInfo.environment["JARVIS_LOCAL_MODEL"], !model.isEmpty else { throw XCTSkip("Set JARVIS_LOCAL_MODEL to an installed Ollama model") }
        let cli = try XCTUnwrap(CLILocator.find("codex"))
        let orchestrator = Orchestrator(agent: .codex, executable: cli, codexBackend: CodexBackend(provider: .ollama, model: model))
        let probe = await orchestrator.runJSON(system: "Return one JSON object with a speak field.", schema: #"{"type":"object","additionalProperties":false,"properties":{"speak":{"type":"string"}},"required":["speak"]}"#, prompt: "Rispondi con speak uguale a Ciao")
        XCTAssertEqual(probe.code, 0, String(probe.stderr.suffix(2500)))
        let action = await orchestrator.decide(transcript: "Nel progetto Demo crea una pagina HTML con scritto Ciao", projects: "- Demo · /tmp/demo · [] · codex", sessions: "- (none)", maxSessions: 2, runningCount: 0, context: nil)
        XCTAssertEqual(action.action, .spawn)
        XCTAssertEqual(action.project, "Demo")
        let summary = await orchestrator.summarize(task: "Crea una pagina", project: "Demo", result: "Creata index.html con scritto Ciao", isError: false, exitCode: 0)
        XCTAssertFalse(summary.isEmpty)
        XCTAssertNotEqual(summary, "Demo è pronto.")
    }
    func testLiveLocalWorkerCreatesFileAndResumes() async throws {
        guard let model = ProcessInfo.processInfo.environment["JARVIS_LOCAL_MODEL"], !model.isEmpty else { throw XCTSkip("Set JARVIS_LOCAL_MODEL to an installed Ollama model") }
        let cli = try XCTUnwrap(CLILocator.find("codex"))
        let backend = CodexBackend(provider: .ollama, model: model)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-local-work-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = AgentRunner.arguments(agent: .codex, task: "Crea soltanto prova.txt nella cartella corrente con contenuto esatto PRIMA. Non aprire finestre e non usare MCP.", mode: .acceptEdits, resume: nil, backend: backend)
        let result = await CLILocator.run(cli, first, cwd: dir.path, timeout: 180)
        XCTAssertEqual(result.code, 0, String(result.stderr.suffix(1500)) + String(result.stdout.suffix(2000)))
        let events = result.stdout.split(separator: "\n").flatMap { CodexStreamParser.parse(line: String($0)) }
        let id = try XCTUnwrap(events.compactMap { event -> String? in if case .sessionID(let id) = event { return id }; return nil }.first)
        let file = dir.appendingPathComponent("prova.txt")
        guard FileManager.default.fileExists(atPath: file.path) else {
            return XCTFail("The local model did not create the file: " + String(result.stdout.suffix(2500)))
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "PRIMA")
        let resumed = AgentRunner.arguments(agent: .codex, task: "Nel file prova.txt sostituisci PRIMA con DOPO. Non creare altri file, non aprire finestre e non usare MCP.", mode: .acceptEdits, resume: id, backend: backend)
        let followup = await CLILocator.run(cli, resumed, cwd: dir.path, timeout: 180)
        XCTAssertEqual(followup.code, 0, String(followup.stderr.suffix(1500)) + String(followup.stdout.suffix(2000)))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "DOPO")
    }

}
