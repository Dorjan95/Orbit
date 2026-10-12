import XCTest
import SwiftUI
import AppKit
@testable import Jarvis

final class WorkflowGraphTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OrbitGraph-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root
    }
    @MainActor private func owner(_ root: URL, scenario: [String: Any] = [:]) throws -> Coordinator {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "workflow-worker", withExtension: "py", subdirectory: "Fixtures"))
        for name in ["codex", "claude"] {
            let target = root.appendingPathComponent(name); try Data(contentsOf: source).write(to: target)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path)
        }
        try JSONSerialization.data(withJSONObject: scenario).write(to: root.appendingPathComponent("workflow-scenario.json"))
        let owner = Coordinator(enableServices: false, sessionRoot: root)
        owner.settings.settings = Settings()
        owner.settings.settings.codexInteractiveControls = false; owner.settings.settings.claudeInteractiveControls = false
        owner.settings.settings.speakSummaries = false; owner.settings.settings.openResults = false
        owner.settings.settings.codexPathOverride = root.appendingPathComponent("codex").path
        owner.settings.settings.claudePathOverride = root.appendingPathComponent("claude").path
        return owner
    }
    @MainActor private func wait(_ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(10)
        while !condition() && Date() < end { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "Graph did not reach expected state")
    }
    @MainActor private func start(_ owner: Coordinator, root: URL, graph: WorkflowDefinition = .standard, command: String = "test -f implementation.txt") throws -> String {
        XCTAssertTrue(owner.startWorkflow(project: Project(name: "Graph", path: root.path), agent: .codex, reviewer: .codex,
            task: "Implement the requirement", verificationCommand: command, definition: graph))
        return try XCTUnwrap(owner.sessions.sessions.first?.id)
    }
    private func launches(_ root: URL) throws -> [[String: Any]] {
        try String(contentsOf: root.appendingPathComponent("worker-launches.jsonl"), encoding: .utf8).split(whereSeparator: \.isNewline)
            .map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
    }
    @MainActor func testReadOnlyPlanApprovalIsDurableAndFreezesIndependentModels() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let owner = try owner(root); defer { owner.stopAll() }
        var graph = WorkflowDefinition.standard
        graph.nodes[0].agent = .claude; graph.nodes[0].model = "planner-model"
        graph.nodes[2].model = "implementer-model"; graph.nodes[3].model = "review-model"
        let id = try start(owner, root: root, graph: graph)
        owner.settings.settings.workflowDefinition.requiresPlanApproval = false
        owner.settings.settings.codexModel = "changed-model"
        try await wait { owner.sessions.session(id)?.workflow?.awaitingPlanApproval == true }
        let pending = try XCTUnwrap(owner.sessions.session(id))
        XCTAssertEqual(pending.turns?.count, 1); XCTAssertFalse(pending.canResumeQueue)
        XCTAssertFalse(owner.resumePending(sessionID: id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("implementation.txt").path))
        let runs = try launches(root); let args = try XCTUnwrap(runs[0]["args"] as? [String])
        XCTAssertTrue(args.contains("planner-model")); XCTAssertTrue(args.contains("Read,Glob,Grep"))
        XCTAssertEqual(pending.workflow?.definition, graph)
        XCTAssertEqual(SessionStore(root: root).session(id)?.workflow?.awaitingPlanApproval, true)
        XCTAssertTrue(owner.decidePlan(sessionID: id, approve: true))
        XCTAssertFalse(owner.decidePlan(sessionID: id, approve: true))
        try await wait { owner.sessions.session(id)?.workflow?.state == .completed }
        let final = try XCTUnwrap(owner.sessions.session(id))
        XCTAssertEqual(final.turns?.map(\.workflowNodeID), ["plan", "implementation", "review", "verification"])
        XCTAssertEqual(final.turns?[1].configuration.model, "implementer-model")
        XCTAssertEqual(final.turns?[2].configuration.model, "review-model")
        XCTAssertTrue(final.turns?[1].task.contains("Modificare implementation.txt") == true)
        let events = try SessionJournal(url: root.appendingPathComponent("session-events.jsonl")).replay()
        let approved = try XCTUnwrap(events.firstIndex { $0.kind == .planApproved })
        let implemented = try XCTUnwrap(events.firstIndex { $0.kind == .dispatched && $0.session.turns?.last?.workflowNodeID == "implementation" })
        XCTAssertLessThan(approved, implemented)
        XCTAssertEqual(events.first?.session.workflow?.nodeConfigurations?["review"]?.model, "review-model")
    }
    @MainActor func testRejectStopAndMissingPlansCannotImplement() async throws {
        for scenario in [[:], ["planMalformed": true], ["planStale": true], ["planDuplicate": true], ["planBlocked": true]] {
            let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
            let owner = try owner(root, scenario: scenario); defer { owner.stopAll() }
            let id = try start(owner, root: root)
            try await wait { owner.sessions.session(id)?.currentTurnID == nil }
            if scenario.isEmpty { XCTAssertTrue(owner.decidePlan(sessionID: id, approve: false)) }
            XCTAssertFalse(owner.decidePlan(sessionID: id, approve: true)); XCTAssertFalse(owner.resumePending(sessionID: id))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("implementation.txt").path))
        }
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let owner = try owner(root); defer { owner.stopAll() }
        let id = try start(owner, root: root)
        try await wait { owner.sessions.session(id)?.workflow?.awaitingPlanApproval == true }
        owner.stop(sessionID: id)
        XCTAssertFalse(owner.decidePlan(sessionID: id, approve: true))
    }
    @MainActor func testAutomaticPlanAndConfiguredCommandLoopUseRealExitCodes() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let owner = try owner(root); defer { owner.stopAll() }
        var graph = WorkflowDefinition.standard; graph.requiresPlanApproval = false
        graph.nodes[2].success = "retry"
        graph.nodes.append(WorkflowNode(id: "retry", kind: .command, title: "Retry local action", command: "n=$(cat count.txt 2>/dev/null || printf 0); n=$((n+1)); printf %s $n > count.txt; test $n -ge 3", success: "review", failure: "retry", maxVisits: 3, x: 800, y: 30))
        let id = try start(owner, root: root, graph: graph)
        try await wait { owner.sessions.session(id)?.workflow?.state == .completed }
        let final = try XCTUnwrap(owner.sessions.session(id))
        XCTAssertEqual(final.turns?.filter { $0.workflowNodeID == "retry" }.map(\.exitCode), [1, 1, 0])
        XCTAssertEqual(final.workflow?.nodeVisits?["retry"], 3)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("count.txt"), encoding: .utf8), "3")
        XCTAssertTrue(final.workflow?.planApproved == true)
    }
    @MainActor func testGraphCorrectionBranchesAndExhaustion() async throws {
        for reviewSequence in [["failed", "passed"], ["failed", "failed", "failed"]] {
            let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
            let owner = try owner(root, scenario: ["reviewSequence": reviewSequence]); defer { owner.stopAll() }
            var graph = WorkflowDefinition.standard; graph.requiresPlanApproval = false
            let id = try start(owner, root: root, graph: graph)
            try await wait { [.completed, .failed].contains(owner.sessions.session(id)?.workflow?.state) }
            let final = try XCTUnwrap(owner.sessions.session(id))
            XCTAssertEqual(final.workflow?.state, reviewSequence.count == 2 ? .completed : .failed)
            XCTAssertEqual(final.workflow?.attempt, reviewSequence.count == 2 ? 1 : 2)
            XCTAssertFalse(final.canResumeQueue)
            XCTAssertTrue(final.turns?.filter { $0.workflowNodeID == "correction" }.allSatisfy { $0.repairSourceTurnID != nil } == true)
        }
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let owner = try owner(root); defer { owner.stopAll() }
        var graph = WorkflowDefinition.standard; graph.requiresPlanApproval = false
        let id = try start(owner, root: root, graph: graph, command: "test -f corrected.txt")
        try await wait { owner.sessions.session(id)?.workflow?.state == .completed }
        XCTAssertEqual(owner.sessions.session(id)?.turns?.filter { $0.workflowNodeID == "verification" }.map(\.exitCode), [1, 0])
    }
    @MainActor func testCorrectionUsesSelectedAgentAndFrozenModelAfterReviewOrVerificationFailure() async throws {
        for agent in [AgentKind.codex, .claude] {
            for source in ["review", "verification"] {
                let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
                let owner = try owner(root, scenario: source == "review" ? ["reviewSequence": ["failed", "passed"]] : [:]); defer { owner.stopAll() }
                var graph = WorkflowDefinition.standard; graph.requiresPlanApproval = false
                graph.nodes[2].agent = agent == .codex ? .claude : .codex
                let index = try XCTUnwrap(graph.nodes.firstIndex { $0.kind == .correction })
                graph.nodes[index].agent = agent; graph.nodes[index].model = "repair-model"; graph.nodes[index].maxVisits = 1
                let id = try start(owner, root: root, graph: graph, command: source == "verification" ? "test -f corrected.txt" : "true")
                owner.settings.settings.codingModel = "changed-claude"; owner.settings.settings.codexModel = "changed-codex"
                owner.settings.settings.workflowDefinition = .empty
                try await wait { owner.sessions.session(id)?.workflow?.state == .completed }
                let session = try XCTUnwrap(owner.sessions.session(id))
                let repair = try XCTUnwrap(session.turns?.first { $0.workflowNodeID == "correction" })
                XCTAssertEqual(repair.configuration.agent, agent); XCTAssertEqual(repair.configuration.model, "repair-model")
                XCTAssertEqual(repair.configuration.codex?.model, agent == .codex ? "repair-model" : nil)
                XCTAssertFalse(repair.configuration.readOnly == true)
                let failed = try XCTUnwrap(session.turns?.first { $0.id == repair.repairSourceTurnID })
                XCTAssertEqual(failed.workflowNodeID, source)
                XCTAssertEqual(session.workflow?.attempt, 1); XCTAssertEqual(session.workflow?.nodeVisits?["correction"], 1)
                XCTAssertEqual(session.workflow?.reviewPassed, true); XCTAssertEqual(session.workflow?.verificationPassed, true)
                XCTAssertTrue(repair.task.contains(source == "review" ? "Review failed:" : "Verification exited with code 1:"))
                XCTAssertEqual(SessionStore(root: root).session(id)?.workflow?.nodeConfigurations?["correction"]?.agent, agent)
            }
        }
    }
    @MainActor func testClaudeCorrectionsStopAtBudgetAndInheritConfiguredModel() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let owner = try owner(root, scenario: ["reviewSequence": ["failed", "failed"]]); defer { owner.stopAll() }
        owner.settings.settings.codingModel = "configured-claude"
        var graph = WorkflowDefinition.standard; graph.requiresPlanApproval = false
        graph.nodes[5].agent = .claude; graph.nodes[5].maxVisits = 1
        let id = try start(owner, root: root, graph: graph)
        try await wait { owner.sessions.session(id)?.workflow?.state == .failed }
        let session = try XCTUnwrap(owner.sessions.session(id))
        XCTAssertEqual(session.turns?.filter { $0.workflowNodeID == "correction" }.count, 1)
        XCTAssertEqual(session.turns?.first { $0.workflowNodeID == "correction" }?.configuration.model, "configured-claude")
        XCTAssertFalse(session.canResumeQueue)
        XCTAssertTrue(session.workflow?.detail.contains("Limite raggiunto") == true)
    }
    @MainActor func testStandardAIPhasesUseIndependentModelsInstructionsAndPreviousResults() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let owner = try owner(root); defer { owner.stopAll() }
        var graph = WorkflowDefinition.empty; var ids: [String] = []
        for (index, kind) in [WorkflowNodeKind.research, .analysis, .testing, .documentation, .summary].enumerated() {
            var node = kind.template
            node.agent = index % 2 == 0 ? .codex : .claude; node.model = "model-" + kind.rawValue
            if kind == .analysis { node.instructions = "Confronta tre alternative senza modificare file." }
            if kind == .testing { node.repetitions = 2; node.maxVisits = 2 }
            ids.append(try XCTUnwrap(graph.insertNode(node, after: ids.last)))
        }
        let id = try start(owner, root: root, graph: graph, command: "")
        try await wait { owner.sessions.session(id)?.workflow?.state == .completed }
        let session = try XCTUnwrap(owner.sessions.session(id))
        let turns = try XCTUnwrap(session.turns)
        XCTAssertEqual(turns.map(\.workflowNodeID), [ids[0], ids[1], ids[2], ids[2], ids[3], ids[4]])
        XCTAssertTrue(turns.allSatisfy { $0.workflowStage == .action })
        for (index, turn) in turns.enumerated() {
            let node = try XCTUnwrap(graph.node(turn.workflowNodeID))
            XCTAssertEqual(turn.configuration.agent, node.agent); XCTAssertEqual(turn.configuration.model, node.model)
            XCTAssertTrue(turn.task.contains(node.resolvedInstructions))
            if index > 0 { XCTAssertTrue(turn.task.contains(turns[index - 1].id.uuidString)) }
            XCTAssertNotNil(AgentWorkflow.actionReport(turn.resultText ?? "", token: turn.id))
        }
        XCTAssertNil(session.workflow?.plan)
        XCTAssertEqual(SessionStore(root: root).session(id)?.workflow?.definition, graph)
    }
    @MainActor func testStandardTestingCanBranchToClaudeCorrectionWithoutMandatoryDevelopmentPhases() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let owner = try owner(root, scenario: ["actionSequence": ["failed", "passed"]]); defer { owner.stopAll() }
        var graph = WorkflowDefinition.empty
        var test = WorkflowNodeKind.testing.template; test.id = "test"; test.failure = "fix"; test.maxVisits = 2
        var fix = WorkflowNodeKind.correction.template; fix.id = "fix"; fix.agent = .claude; fix.success = "test"; fix.maxVisits = 1
        graph.entry = "test"; graph.nodes = [test, fix]
        let id = try start(owner, root: root, graph: graph, command: "")
        try await wait { owner.sessions.session(id)?.workflow?.state == .completed }
        let session = try XCTUnwrap(owner.sessions.session(id))
        XCTAssertEqual(session.turns?.map(\.workflowNodeID), ["test", "fix", "test"])
        let correction = try XCTUnwrap(session.turns?.first { $0.workflowNodeID == "fix" })
        XCTAssertEqual(correction.configuration.agent, .claude)
        XCTAssertEqual(correction.repairSourceTurnID, session.turns?.first?.id)
        XCTAssertTrue(correction.task.contains("configured workflow action"))
        XCTAssertTrue(correction.task.contains("Esito azione personalizzata"))
        XCTAssertFalse(correction.task.contains("then run verification again"))
        XCTAssertNil(session.workflow?.plan); XCTAssertNil(session.workflow?.verificationPassed)
    }
    @MainActor func testLoopsStopAtBudgetAndCannotSkipReview() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let owner = try owner(root); defer { owner.stopAll() }
        var graph = WorkflowDefinition.standard; graph.requiresPlanApproval = false
        graph.nodes[2].success = "command"
        graph.nodes.append(WorkflowNode(id: "command", kind: .command, title: "Failure loop", command: "exit 7", success: "review", failure: "command", maxVisits: 2, x: 800, y: 30))
        let id = try start(owner, root: root, graph: graph)
        try await wait { owner.sessions.session(id)?.workflow?.state == .failed }
        XCTAssertEqual(owner.sessions.session(id)?.turns?.filter { $0.workflowNodeID == "command" }.count, 2)
        XCTAssertTrue(owner.sessions.session(id)?.workflow?.detail.contains("Limite raggiunto") == true)
        // A valid-looking saved path cannot override the runtime review gate.
        var session = try XCTUnwrap(owner.sessions.session(id))
        session.workflow?.state = .dispatched; session.workflow?.definition?.nodes[2].success = "verification"
        session.workflow?.currentNodeID = "implementation"
        session.turns?.append(SessionTurn(task: "done", configuration: AgentExecutionConfiguration(agent: .codex, permissionMode: .acceptEdits), state: .completed, workflowStage: .implementation, workflowNodeID: "implementation"))
        session.status = .done
        owner.advanceGraphWorkflow(&session, turnID: session.turns!.last!.id, code: 0)
        XCTAssertEqual(session.workflow?.state, .blocked)
        XCTAssertTrue(session.workflow?.detail.contains("review superata") == true)
    }
    @MainActor func testApprovalPersistenceFailureAndRecoveryNeverLaunchesWork() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let owner = try owner(root); defer { owner.stopAll() }
        let id = try start(owner, root: root)
        try await wait { owner.sessions.session(id)?.workflow?.awaitingPlanApproval == true }
        let recovered = Coordinator(enableServices: false, sessionRoot: root); defer { recovered.stopAll() }
        XCTAssertEqual(recovered.sessions.session(id)?.workflow?.awaitingPlanApproval, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("implementation.txt").path))
        let journal = root.appendingPathComponent("session-events.jsonl")
        try FileManager.default.removeItem(at: journal)
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true)
        XCTAssertFalse(owner.decidePlan(sessionID: id, approve: true))
        XCTAssertEqual(owner.sessions.session(id)?.workflow?.awaitingPlanApproval, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("implementation.txt").path))
    }
    @MainActor func testGlobalBudgetAndInterruptedGraphCannotReplay() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let owner = Coordinator(enableServices: false, sessionRoot: root)
        let config = AgentExecutionConfiguration(agent: .codex, permissionMode: .acceptEdits)
        let turn = SessionTurn(task: "Done", configuration: config, state: .completed, workflowStage: .implementation, workflowNodeID: "implementation")
        var session = Session(id: "budget", projectName: "Graph", projectPath: root.path, agent: .codex, task: "Build", status: .done, turns: [turn],
            workflow: AgentWorkflow(originalTask: "Build", verificationCommand: "true", definition: .standard,
                nodeConfigurations: ["review": config], currentNodeID: "implementation", stepsExecuted: 64, planApproved: true))
        owner.advanceGraphWorkflow(&session, turnID: turn.id, code: 0)
        XCTAssertEqual(session.workflow?.state, .failed)
        XCTAssertTrue(session.workflow?.detail.contains("Limite raggiunto") == true)
        XCTAssertEqual(session.turns?.count, 1)
        session.id = "interrupted"; session.workflow?.state = .dispatched; session.currentTurnID = turn.id; session.status = .running
        session.turns?[0].state = .dispatched
        try owner.sessions.save(session, kind: .dispatched, turnID: turn.id)
        let recovered = SessionStore(root: root)
        XCTAssertEqual(recovered.session(session.id)?.turns?.first?.state, .interrupted)
        XCTAssertFalse(recovered.session(session.id)?.canResumeQueue ?? true)
    }

    func testGraphValidationAndLegacySettingsCompatibility() throws {
        XCTAssertNil(WorkflowDefinition.standard.validationError)
        var invalid = WorkflowDefinition.standard; invalid.nodes[0].success = "absent"
        XCTAssertNotNil(invalid.validationError)
        invalid = .standard; invalid.nodes[5].maxVisits = 4; XCTAssertNotNil(invalid.validationError)
        let old = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
        XCTAssertEqual(old.workflowDefinition, .standard)
        let encoded = try JSONEncoder().encode(old)
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: encoded).workflowDefinition, .standard)
    }
    @MainActor func testCustomAIActionsAndShellCommandsRunWithFrozenModelsAndBoundedLoops() async throws {
        for agent in [AgentKind.codex, .claude] {
            let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
            let owner = try owner(root, scenario: ["actionSequence": ["failed", "passed"]]); defer { owner.stopAll() }
            var graph = WorkflowDefinition.standard; graph.requiresPlanApproval = false
            let action = try XCTUnwrap(graph.insertCustomAction(WorkflowNode(id: "", kind: .action, title: "Documentazione", agent: agent, model: "action-model", instructions: "Aggiorna README e spiega il risultato", maxVisits: 2, x: 0, y: 0)))
            let shell = try XCTUnwrap(graph.insertCustomAction(WorkflowNode(id: "", kind: .command, title: "Controllo file", command: "test -f implementation.txt", x: 0, y: 0)))
            let index = try XCTUnwrap(graph.nodes.firstIndex { $0.id == action }); graph.nodes[index].failure = action
            let id = try start(owner, root: root, graph: graph, command: "test -f action.txt")
            owner.settings.settings.codexModel = "changed-after-start"; owner.settings.settings.codingModel = "changed-after-start"
            try await wait { owner.sessions.session(id)?.workflow?.state == .completed }
            let session = try XCTUnwrap(owner.sessions.session(id))
            XCTAssertEqual(session.turns?.map(\.workflowNodeID), ["plan", "implementation", shell, action, action, "review", "verification"])
            let actions = session.turns?.filter { $0.workflowNodeID == action } ?? []
            XCTAssertEqual(actions.map(\.state), [.failed, .completed])
            XCTAssertTrue(actions.allSatisfy { $0.configuration.agent == agent && $0.configuration.model == "action-model" })
            XCTAssertTrue(actions.allSatisfy { $0.task.contains("Aggiorna README") && $0.task.contains("ORBIT_ACTION_REPORT:") })
            XCTAssertEqual(session.workflow?.definition, graph)
            XCTAssertEqual(SessionStore(root: root).session(id)?.workflow?.definition, graph)
            XCTAssertEqual(session.workflow?.nodeVisits?[action], 2)
        }
    }
    @MainActor func testResearchOnlyWorkflowRepeatsWithoutPlanOrVerificationWithEitherAgent() async throws {
        for agent in [AgentKind.codex, .claude] {
            let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
            let owner = try owner(root); defer { owner.stopAll() }
            var graph = WorkflowDefinition.research
            graph.nodes[0].agent = agent; graph.nodes[0].model = "research-model"
            graph.nodes[0].repetitions = 3; graph.nodes[0].maxVisits = 3
            let id = try start(owner, root: root, graph: graph, command: "")
            owner.settings.settings.workflowDefinition = .standard
            try await wait { owner.sessions.session(id)?.workflow?.state == .completed }
            let session = try XCTUnwrap(owner.sessions.session(id))
            XCTAssertEqual(session.turns?.count, 3)
            XCTAssertTrue(session.turns?.allSatisfy { $0.workflowStage == .action && $0.configuration.agent == agent && $0.configuration.model == "research-model" } == true)
            XCTAssertEqual(session.workflow?.nodeVisits?["research"], 3)
            XCTAssertNil(session.workflow?.plan); XCTAssertNil(session.workflow?.reviewPassed); XCTAssertNil(session.workflow?.verificationPassed)
            XCTAssertTrue(session.turns?[0].task.contains("No planning step") == true)
            XCTAssertTrue(session.turns?[2].task.contains("Repetition: 3 of 3") == true)
            XCTAssertFalse(session.turns?[0].task.contains("independently reviews and verifies") == true)
            XCTAssertEqual(SessionStore(root: root).session(id)?.workflow?.definition, graph)
        }
    }
    @MainActor func testShellOnlyWorkflowAndDirectVerificationNeedNoAIExecutables() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let owner = try owner(root); defer { owner.stopAll() }
        owner.settings.settings.codexPathOverride = "/does-not-exist/codex"; owner.settings.settings.claudePathOverride = "/does-not-exist/claude"
        var graph = WorkflowDefinition.empty
        let action = try XCTUnwrap(graph.insertNode(WorkflowNode(id: "", kind: .command, title: "Ripeti controllo", command: "printf 'ok\\n' >> repeats.txt", repetitions: 3, maxVisits: 3, x: 0, y: 0)))
        let id = try start(owner, root: root, graph: graph, command: "")
        try await wait { owner.sessions.session(id)?.workflow?.state == .completed }
        XCTAssertEqual(owner.sessions.session(id)?.turns?.map(\.workflowNodeID), [action, action, action])
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("repeats.txt"), encoding: .utf8), "ok\nok\nok\n")
        graph = .empty
        _ = graph.insertNode(WorkflowNode(id: "", kind: .verification, title: "Solo verifica", x: 0, y: 0))
        let check = try start(owner, root: root, graph: graph, command: "test -f repeats.txt")
        try await wait { owner.sessions.session(check)?.workflow?.state == .completed }
        XCTAssertEqual(owner.sessions.session(check)?.turns?.map(\.workflowStage), [.verification])
    }
    @MainActor func testFlexibleConditionalLoopCanSucceedOrStopAtBudgetWithoutOtherPhases() async throws {
        for sequence in [["failed", "passed"], ["failed", "failed", "failed"]] {
            let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
            let owner = try owner(root, scenario: ["actionSequence": sequence]); defer { owner.stopAll() }
            var graph = WorkflowDefinition.research
            graph.nodes[0].failure = "research"; graph.nodes[0].maxVisits = 2
            let id = try start(owner, root: root, graph: graph, command: "")
            try await wait { [.completed, .failed].contains(owner.sessions.session(id)?.workflow?.state) }
            XCTAssertEqual(owner.sessions.session(id)?.workflow?.state, sequence.count == 2 ? .completed : .failed)
            XCTAssertEqual(owner.sessions.session(id)?.turns?.count, 2)
            XCTAssertFalse(owner.sessions.session(id)?.canResumeQueue ?? true)
        }
    }
    @MainActor func testFlexiblePlanStillRequiresApprovalAndCanEndAtApproval() async throws {
        for includeAction in [true, false] {
            let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
            let owner = try owner(root); defer { owner.stopAll() }
            var graph = WorkflowDefinition.empty
            let plan = try XCTUnwrap(graph.insertNode(WorkflowNode(id: "", kind: .plan, title: "Piano", x: 0, y: 0)))
            let approval = try XCTUnwrap(graph.insertNode(WorkflowNode(id: "", kind: .approval, title: "Approva", x: 0, y: 0), after: plan))
            if includeAction { _ = graph.insertNode(WorkflowDefinition.research.nodes[0], after: approval) }
            graph.requiresPlanApproval = true
            let id = try start(owner, root: root, graph: graph, command: "")
            try await wait { owner.sessions.session(id)?.workflow?.awaitingPlanApproval == true }
            XCTAssertEqual(owner.sessions.session(id)?.turns?.count, 1)
            XCTAssertFalse(owner.sessions.session(id)?.canResumeQueue ?? true)
            XCTAssertTrue(owner.decidePlan(sessionID: id, approve: true))
            try await wait { owner.sessions.session(id)?.workflow?.state == .completed }
            XCTAssertEqual(owner.sessions.session(id)?.turns?.count, includeAction ? 2 : 1)
            XCTAssertNil(owner.sessions.session(id)?.workflow?.reviewPassed)
        }
    }
    @MainActor func testAIActionsBlockMalformedOutcomesAndCannotSkipFreshReview() async throws {
        for scenario: [String: Any] in [["actionExit": 7], ["actionMalformed": true], ["actionStale": true], ["actionDuplicate": true], ["actionVerdict": "blocked"], ["actionVerdict": "failed"]] {
            let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
            let owner = try owner(root, scenario: scenario); defer { owner.stopAll() }
            var graph = WorkflowDefinition.standard; graph.requiresPlanApproval = false
            let action = try XCTUnwrap(graph.insertCustomAction(WorkflowNode(id: "", kind: .action, title: "Controllo", instructions: "Controlla il risultato", maxVisits: 2, x: 0, y: 0)))
            let index = try XCTUnwrap(graph.nodes.firstIndex { $0.id == action }); graph.nodes[index].failure = action
            let id = try start(owner, root: root, graph: graph)
            try await wait { [.blocked, .failed].contains(owner.sessions.session(id)?.workflow?.state) }
            let session = try XCTUnwrap(owner.sessions.session(id))
            XCTAssertFalse(session.canResumeQueue)
            XCTAssertFalse(session.turns?.contains { $0.workflowStage == .review } ?? true)
            XCTAssertLessThanOrEqual(session.workflow?.nodeVisits?[action] ?? 0, 2)
        }
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let owner = try owner(root); defer { owner.stopAll() }
        var graph = WorkflowDefinition.standard; graph.requiresPlanApproval = false
        let action = try XCTUnwrap(graph.insertCustomAction(WorkflowNode(id: "", kind: .action, title: "Dopo i test", instructions: "Modifica un file", x: 0, y: 0)))
        graph.nodes[2].success = "review"; graph.nodes[4].success = action
        graph.nodes[try XCTUnwrap(graph.nodes.firstIndex { $0.id == action })].success = nil
        let id = try start(owner, root: root, graph: graph)
        try await wait { [.blocked, .failed, .completed].contains(owner.sessions.session(id)?.workflow?.state) }
        let session = try XCTUnwrap(owner.sessions.session(id))
        XCTAssertEqual(session.workflow?.state, .failed, session.workflow?.detail ?? "")
        XCTAssertNil(session.workflow?.reviewPassed); XCTAssertNil(session.workflow?.verificationPassed)
        XCTAssertTrue(session.workflow?.detail.contains("senza review e verifica valide") == true)
    }
    @MainActor func testEditorAndApprovalScreens() throws {
        guard let path = ProcessInfo.processInfo.environment["ORBIT_GRAPH_PREVIEW_DIR"] else { throw XCTSkip("Optional graph UI snapshots") }
        let output = URL(fileURLWithPath: path); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var illustrated = WorkflowDefinition.standard
        let positions: [(Double, Double)] = [(30, 30), (275, 30), (520, 30), (765, 30), (1010, 30), (520, 270)]
        for index in illustrated.nodes.indices { illustrated.nodes[index].x = positions[index].0; illustrated.nodes[index].y = positions[index].1 }
        illustrated.nodes[5].agent = .claude
        for reduced in [false, true] {
            let view = NSHostingView(rootView: WorkflowEditorView(definition: .constant(illustrated)).transaction { $0.disablesAnimations = reduced })
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1280, height: 820), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view; view.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1)); view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(reduced ? "editor-reduced.png" : "editor.png"))
            window.contentView = nil
        }
        var graph = WorkflowDefinition.standard
        graph.nodes[5].agent = .claude; graph.nodes[5].model = "repair-model"
        graph.nodes.append(WorkflowNode(id: "command-preview", kind: .command, title: "Controllo locale", command: "swift test", success: "review", x: 790, y: 30))
        graph.nodes.append(WorkflowNode(id: "action-preview", kind: .action, title: "Aggiorna documentazione", agent: .claude, instructions: "Aggiorna README con le funzionalità implementate. Preserva le istruzioni esistenti.", success: "review", x: 1050, y: 30))
        for kind in [WorkflowNodeKind.research, .analysis, .testing, .documentation, .summary] {
            var node = kind.template; node.id = kind.rawValue + "-preview"; graph.nodes.append(node)
        }
        for node in graph.nodes {
            let panel = NSHostingView(rootView: WorkflowNodeInspector(node: .constant(node), definition: graph, requiresPlanApproval: true, disconnect: { _ in }, delete: {}, saveAction: node.kind.canSaveAction ? {} : nil)
                .frame(width: 250).fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(OrbitDesign.chalk).tint(OrbitDesign.lime).preferredColorScheme(.dark))
            panel.frame = CGRect(x: 0, y: 0, width: 250, height: panel.fittingSize.height)
            panel.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(panel.bitmapImageRepForCachingDisplay(in: panel.bounds)); panel.cacheDisplay(in: panel.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("inspector-" + node.kind.rawValue + ".png"))
        }
        var library = WorkflowLibrary()
        let duplicate = library.create(copying: library.defaultID)
        var alternate = WorkflowDefinition.standard; alternate.name = "Documentazione e controlli"
        library.update(duplicate, definition: alternate)
        for node in graph.nodes where node.kind.canSaveAction { library.saveAction(node) }
        func snapshot<V: View>(_ root: V, name: String, size: CGSize) throws {
            let host = NSHostingView(rootView: root.foregroundStyle(OrbitDesign.chalk).tint(OrbitDesign.lime).preferredColorScheme(.dark))
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host; host.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.1)); host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
            window.contentView = nil
        }
        for reduced in [false, true] {
            let suffix = reduced ? "-reduced" : ""
            for node in graph.nodes where node.kind == .correction || node.kind.defaultInstructions != nil {
                try snapshot(WorkflowNodeInspector(node: .constant(node), definition: graph, requiresPlanApproval: true, disconnect: { _ in }, delete: {}, saveAction: node.kind.canSaveAction ? {} : nil).frame(width: 250).transaction { $0.disablesAnimations = reduced }, name: "phase-" + node.kind.rawValue + suffix, size: CGSize(width: 250, height: 590))
            }
            var research = WorkflowDefinition.research; research.nodes[0].repetitions = 3; research.nodes[0].maxVisits = 3
            for (name, definition) in [("empty", WorkflowDefinition.empty), ("research", research)] {
                try snapshot(WorkflowEditorView(definition: .constant(definition)).transaction { $0.disablesAnimations = reduced }, name: "editor-" + name + suffix, size: CGSize(width: 1280, height: 820))
            }
            try snapshot(WorkflowActionPicker(definition: .empty, library: .constant(library), initialCategory: .standard, select: { _ in }, add: { _ in }).transaction { $0.disablesAnimations = reduced }, name: "actions-empty" + suffix, size: CGSize(width: 500, height: 610))
            try snapshot(ScrollView { WorkflowLibraryView(library: .constant(library)).padding(24) }.background(OrbitDesign.screen).transaction { $0.disablesAnimations = reduced }, name: "library" + suffix, size: CGSize(width: 730, height: 820))
            for category in WorkflowActionCategory.allCases {
                try snapshot(WorkflowActionPicker(definition: .standard, library: .constant(library), initialCategory: category, select: { _ in }, add: { _ in }).transaction { $0.disablesAnimations = reduced }, name: "actions-" + category.id + suffix, size: CGSize(width: 500, height: 610))
            }
        }
        let previewRoot = try directory(); defer { try? FileManager.default.removeItem(at: previewRoot) }
        let previewOwner = Coordinator(enableServices: false, sessionRoot: previewRoot)
        previewOwner.settings.settings.workflowLibrary = library
        previewOwner.registry.projects = [Project(name: "Progetto demo", path: previewRoot.path, verificationCommand: "swift test")]
        try snapshot(WorkflowLaunchView(coordinator: previewOwner), name: "launch", size: CGSize(width: 530, height: 650))
        let researchID = previewOwner.settings.settings.workflowLibrary.create()
        previewOwner.settings.settings.workflowLibrary.update(researchID, definition: .research)
        previewOwner.settings.settings.workflowLibrary.setDefault(researchID)
        previewOwner.registry.projects = []
        for reduced in [false, true] {
            try snapshot(WorkflowLaunchView(coordinator: previewOwner).transaction { $0.disablesAnimations = reduced }, name: reduced ? "launch-research-reduced" : "launch-research", size: CGSize(width: 530, height: 690))
        }
        for reduced in [false, true] {
            try snapshot(SettingsView(coordinator: previewOwner, section: .workflows).transaction { $0.disablesAnimations = reduced }, name: reduced ? "settings-reduced" : "settings", size: CGSize(width: 820, height: 680))
        }
        let config = AgentExecutionConfiguration(agent: .codex, permissionMode: .acceptEdits)
        let session = Session(id: "preview", projectName: "Demo", projectPath: "/tmp/demo", agent: .codex, task: "Aggiungi una ricerca", status: .needsInput,
            turns: [SessionTurn(task: "Piano", configuration: config, state: .completed, workflowStage: .planning, workflowNodeID: "plan")],
            workflow: AgentWorkflow(originalTask: "Aggiungi una ricerca", verificationCommand: "swift test", state: .blocked, detail: "Piano pronto. Leggilo e scegli se approvarlo.", definition: .standard,
                plan: AgentWorkflow.PlanReport(token: UUID(), verdict: "ready", summary: "Aggiungere una ricerca nella lista dei progetti.", steps: ["Modificare ProjectsTab con un campo di ricerca accessibile.", "Filtrare per nome e alias senza modificare i dati.", "Review indipendente e swift test."]), planApproved: false, awaitingPlanApproval: true))
        let view = NSHostingView(rootView: WorkflowProgressView(session: session).padding(20).frame(width: 520).background(OrbitDesign.screen).foregroundStyle(OrbitDesign.chalk).preferredColorScheme(.dark))
        view.frame = CGRect(x: 0, y: 0, width: 520, height: 590); view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("approval.png"))
    }
}

extension WorkflowGraphTests {
    @MainActor func testScoreLoopRetriesWithFeedbackStopsAtThresholdAndPersists() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let owner = try owner(root, scenario: ["scoreSequence": [65, 90]])
        defer { owner.stopAll() }
        var graph = WorkflowDefinition.scoreLoop
        graph.nodes[0].agent = .claude; graph.nodes[0].model = "worker-model"
        graph.nodes[1].model = "judge-model"
        let id = try start(owner, root: root, graph: graph, command: "")
        try await wait { owner.sessions.session(id)?.workflow?.state == .completed }
        let session = try XCTUnwrap(owner.sessions.session(id))
        XCTAssertEqual(session.turns?.count, 4)
        XCTAssertEqual(session.workflow?.scoreResults?.map(\.score), [65, 90])
        XCTAssertEqual(session.workflow?.nodeVisits?["work"], 2)
        XCTAssertEqual(session.workflow?.nodeVisits?["score"], 2)
        XCTAssertEqual(session.turns?[0].configuration.model, "worker-model")
        XCTAssertEqual(session.turns?[1].configuration.model, "judge-model")
        XCTAssertEqual(session.turns?[1].configuration.readOnly, true)
        XCTAssertTrue(session.turns?[2].task.contains("Migliorare copertura e precisione" ) == true)
        XCTAssertFalse(session.canResumeQueue)
        let reloaded = SessionStore(root: root)
        XCTAssertEqual(reloaded.session(id)?.workflow?.scoreResults, session.workflow?.scoreResults)
        XCTAssertEqual(try launches(root).map { $0["agent"] as? String }, ["claude", "codex", "claude", "codex"])
    }
    @MainActor func testScoreLoopDoesNotClaimSuccessWhenAttemptsRunOutOrFailureEdgeMissing() async throws {
        for noEdge in [false, true] {
            let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
            let owner = try owner(root, scenario: ["scoreSequence": [55]])
            defer { owner.stopAll() }
            var graph = WorkflowDefinition.scoreLoop
            graph.nodes[0].maxVisits = 2; graph.nodes[1].maxVisits = 2
            if noEdge { graph.nodes[1].failure = nil }
            let id = try start(owner, root: root, graph: graph, command: "")
            try await wait { owner.sessions.session(id)?.workflow?.state == .failed }
            let session = try XCTUnwrap(owner.sessions.session(id))
            XCTAssertEqual(session.status, .failed); XCTAssertFalse(session.canResumeQueue)
            XCTAssertEqual(session.turns?.count, noEdge ? 2 : 4)
            XCTAssertEqual(session.workflow?.scoreResults?.last?.score, 55)
            XCTAssertNotEqual(session.workflow?.state, .completed)
        }
    }
    @MainActor func testInvalidOrBlockedScoresNeverTriggerAnotherIteration() async throws {
        for scenario: [String: Any] in [["scoreStale": true], ["scoreMalformed": true], ["scoreDuplicate": true], ["scoreBlocked": true], ["scoreSequence": [101]]] {
            let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
            let owner = try owner(root, scenario: scenario); defer { owner.stopAll() }
            let id = try start(owner, root: root, graph: .scoreLoop, command: "")
            try await wait { owner.sessions.session(id)?.workflow?.state == .blocked }
            XCTAssertEqual(owner.sessions.session(id)?.turns?.count, 2)
            XCTAssertTrue(owner.sessions.session(id)?.workflow?.scoreResults?.isEmpty ?? true)
            XCTAssertFalse(owner.sessions.session(id)?.canResumeQueue ?? true)
        }
    }
}
