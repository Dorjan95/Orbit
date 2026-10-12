import XCTest
@testable import Jarvis

final class RemovedProviderMigrationTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OrbitRemovedProvider-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testOnlyNativeAgentsCanBeSelectedOrReturnedByInterpreter() throws {
        XCTAssertEqual(Set(AgentKind.allCases), Set([.codex, .claude]))
        XCTAssertFalse(OrchestratorAction.jsonSchema.contains("deepseek"))
        let action = #"{"action":"spawn","agent":"deepseek","project":"Demo","session_id":null,"task":"Test","speak":"Start"}"#
        XCTAssertNil(Orchestrator.parse(resultJSON: action))
        let wrapped = try JSONSerialization.data(withJSONObject: ["result": action])
        XCTAssertNil(Orchestrator.parse(resultJSON: String(decoding: wrapped, as: UTF8.self)))
        let structured = try JSONSerialization.data(withJSONObject: ["structured_output": JSONSerialization.jsonObject(with: Data(action.utf8))])
        XCTAssertNil(Orchestrator.parse(resultJSON: String(decoding: structured, as: UTF8.self)))
        XCTAssertNotNil(Orchestrator.parse(resultJSON: action.replacingOccurrences(of: "deepseek", with: "codex")))
    }

    func testOldSettingsIgnoreRemovedKeysAndPreserveNativeChoices() throws {
        let raw = #"{"defaultAgent":"deepseek","orchestratorAgent":"claude","codexModel":"chosen-codex","codingModel":"chosen-claude","codexInteractiveControls":false,"claudeInteractiveControls":true,"codexPermissionMode":"acceptEdits","claudePermissionMode":"bypassPermissions","deepseekBackend":{"transport":"acp","provider":"old","model":"old"},"deepseekPathOverride":"/old/dsh","deepseekPermissionMode":"bypassPermissions","mascotSize":180}"#
        let settings = try JSONDecoder().decode(Settings.self, from: Data(raw.utf8))
        XCTAssertEqual(settings.defaultAgent, .codex); XCTAssertEqual(settings.orchestratorAgent, .claude)
        XCTAssertEqual(settings.codexModel, "chosen-codex"); XCTAssertEqual(settings.codingModel, "chosen-claude")
        XCTAssertFalse(settings.codexInteractiveControls); XCTAssertTrue(settings.claudeInteractiveControls)
        XCTAssertEqual(settings.claudePermissionMode, .bypassPermissions); XCTAssertEqual(settings.mascotSize, 180)
        let encoded = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
        XCTAssertFalse(encoded.contains("deepseek")); XCTAssertFalse(encoded.contains("/old/dsh"))
    }

    func testOldProjectMovesToCodexWithoutBroaderPermissionsOrLosingItsIdentity() throws {
        let id = UUID()
        var project = Project(id: id, name: "Existing", path: "/projects/existing", aliases: ["example"],
            defaultAgent: .retiredDeepSeek, permissionMode: .bypassPermissions, verificationCommand: "npm test")
        let data = try JSONEncoder().encode(project)
        let migrated = try JSONDecoder().decode(Project.self, from: data)
        XCTAssertEqual(migrated.id, id); XCTAssertEqual(migrated.name, project.name); XCTAssertEqual(migrated.path, project.path)
        XCTAssertEqual(migrated.aliases, project.aliases); XCTAssertEqual(migrated.verificationCommand, "npm test")
        XCTAssertEqual(migrated.defaultAgent, .codex); XCTAssertEqual(migrated.permissionMode, .acceptEdits)
        project.defaultAgent = .claude
        XCTAssertEqual(try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project)), project)
    }

    @MainActor
    func testLegacyJournalLoadsAllSessionsAndArchivesOnlyRemovedProviderWork() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let nativeConfiguration = AgentExecutionConfiguration(agent: .codex, permissionMode: .acceptEdits, interactiveControls: true)
        let legacyJSON = #"{"agent":"deepseek","permissionMode":"acceptEdits","deepseek":{"transport":"acp","model":"old"},"interactiveControls":true}"#
        let legacyConfiguration = try JSONDecoder().decode(AgentExecutionConfiguration.self, from: Data(legacyJSON.utf8))
        XCTAssertFalse(legacyConfiguration.supportsInteractiveControls)
        let running = SessionTurn(task: "Started", configuration: legacyConfiguration, state: .dispatched)
        let queued = SessionTurn(task: "Queued", configuration: legacyConfiguration)
        let approval = AgentApproval(requestID: .number(900), remoteSessionID: "original-dsh-context", toolCallID: "old-tool",
            title: "Original request", details: "Original details", options: [ApprovalOption(optionID: "allow", name: "Allow", kind: "allow_once")], turnID: running.id)
        let removed = Session(id: "s_01", projectName: "Legacy", projectPath: root.path, agent: .retiredDeepSeek,
            task: "Original task", status: .needsInput, agentSessionID: "original-dsh-context", resultText: "Original output",
            executionConfiguration: legacyConfiguration, turns: [running, queued], currentTurnID: running.id, approvals: [approval])
        let nativeTurn = SessionTurn(task: "Native follow-up", configuration: nativeConfiguration)
        let native = Session(id: "s_02", projectName: "Native", projectPath: root.path, agent: .codex, task: "Native task",
            status: .done, agentSessionID: "native-context", executionConfiguration: nativeConfiguration, turns: [nativeTurn])
        let journal = SessionJournal(url: root.appendingPathComponent("session-events.jsonl"))
        try journal.bootstrap([removed, native])
        let store = SessionStore(root: root)
        XCTAssertNil(store.persistenceError); XCTAssertEqual(store.sessions.count, 2)
        let archived = try XCTUnwrap(store.session(removed.id))
        XCTAssertEqual(archived.agent, .retiredDeepSeek); XCTAssertEqual(archived.agentSessionID, "original-dsh-context")
        XCTAssertEqual(archived.resultText, "Original output"); XCTAssertEqual(archived.task, "Original task")
        XCTAssertEqual(archived.turns?.map(\.id), [running.id, queued.id])
        XCTAssertEqual(archived.turns?.map(\.state), [.interrupted, .cancelled])
        XCTAssertEqual(archived.approvals?.first?.state, .expired)
        XCTAssertNil(archived.currentTurnID); XCTAssertNil(archived.pid); XCTAssertFalse(archived.hasPendingWork)
        XCTAssertFalse(archived.canResumeQueue); XCTAssertFalse(archived.offersSteering)
        XCTAssertEqual(store.session(native.id), native)
        XCTAssertTrue(store.session(native.id)?.canResumeQueue == true)
        let next = SessionStore(root: root)
        XCTAssertNil(next.persistenceError); XCTAssertEqual(next.session(removed.id), archived)
        XCTAssertEqual(try SessionJournal(url: root.appendingPathComponent("session-events.jsonl")).replay().filter { $0.kind == .recovered }.count, 1)
    }

    @MainActor
    func testMixedWorkflowCannotRerouteItsRemovedReviewerOrResumeOldContext() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let native = AgentExecutionConfiguration(agent: .codex, permissionMode: .acceptEdits, interactiveControls: true)
        let removed = AgentExecutionConfiguration(agent: .retiredDeepSeek, permissionMode: .acceptEdits)
        let implementation = SessionTurn(task: "Build", configuration: native, state: .completed, workflowStage: .implementation)
        let review = SessionTurn(task: "Review", configuration: removed, workflowStage: .review)
        let check = SessionTurn(task: "true", configuration: native, workflowStage: .verification)
        let session = Session(id: "s_01", projectName: "Mixed", projectPath: root.path, agent: .codex, task: "Build", status: .done,
            agentSessionID: "native-context", turns: [implementation, review, check], workflow: AgentWorkflow(originalTask: "Build",
                verificationCommand: "true", state: .dispatched, maxCorrections: 2, correctionsScheduled: 0))
        try SessionStore(root: root).save(session, kind: .accepted)
        let owner = Coordinator(enableServices: false, sessionRoot: root); defer { owner.stopAll() }
        let archived = try XCTUnwrap(owner.sessions.session(session.id))
        XCTAssertEqual(archived.workflow?.state, .cancelled); XCTAssertTrue(archived.queuedTurns.isEmpty)
        XCTAssertFalse(owner.resumePending(sessionID: session.id))
        XCTAssertFalse(owner.followUp(session: archived, task: "Reroute the old context"))
        XCTAssertFalse(owner.spawn(project: Project(name: "Mixed", path: root.path), agent: .codex,
            task: "Resume", resume: archived.agentSessionID, existingID: archived.id))
        XCTAssertFalse(owner.startWorkflow(project: Project(name: "Mixed", path: root.path), agent: .codex,
            reviewer: .retiredDeepSeek, task: "Build", verificationCommand: "true"))
        XCTAssertEqual(owner.sessions.sessions.count, 1)
    }

    @MainActor
    func testRemovedProviderCannotLaunchThroughEitherBackend() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let configuration = AgentExecutionConfiguration(agent: .retiredDeepSeek, permissionMode: .acceptEdits, interactiveControls: true)
        let request = AgentRunRequest(executable: "/bin/sh", task: "touch launched.txt", cwd: root.path,
            resume: "old-context", guidance: nil, configuration: configuration)
        let headless = AgentRunner(sessionID: "removed-headless", agent: .retiredDeepSeek, onEvent: { _ in }, onExit: { _, _ in })
        let interactive = NativeAgentBackend(sessionID: "removed-native", agent: .retiredDeepSeek, onEvent: { _ in }, onExit: { _, _ in })
        XCTAssertEqual(headless.capabilities, .unavailable)
        XCTAssertThrowsError(try headless.start(request)); XCTAssertThrowsError(try interactive.start(request))
        XCTAssertFalse(headless.isRunning); XCTAssertFalse(interactive.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("launched.txt").path))
    }
}
