import XCTest
import SwiftUI
import AppKit
@testable import Jarvis

final class WorkflowIntegrationTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OrbitWorkflow-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    @MainActor
    private func owner(_ root: URL, scenario: [String: Any] = [:]) throws -> Coordinator {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "workflow-worker", withExtension: "py", subdirectory: "Fixtures"))
        for name in ["codex", "claude"] {
            let target = root.appendingPathComponent(name)
            try Data(contentsOf: source).write(to: target)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path)
        }
        try JSONSerialization.data(withJSONObject: scenario).write(to: root.appendingPathComponent("workflow-scenario.json"))
        let owner = Coordinator(enableServices: false, sessionRoot: root)
        owner.settings.settings = Settings()
        owner.settings.settings.codexInteractiveControls = false
        owner.settings.settings.claudeInteractiveControls = false
        owner.settings.settings.speakSummaries = false; owner.settings.settings.openResults = false
        owner.settings.settings.codexPathOverride = root.appendingPathComponent("codex").path
        owner.settings.settings.claudePathOverride = root.appendingPathComponent("claude").path
        owner.settings.settings.codexModel = "frozen-model"
        owner.settings.settings.codingModel = "frozen-reviewer"
        return owner
    }
    @MainActor private func wait(_ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(8)
        while !condition() && Date() < end { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "Workflow did not reach its expected state")
    }
    private func launches(_ root: URL) throws -> [[String: Any]] {
        try String(contentsOf: root.appendingPathComponent("worker-launches.jsonl"), encoding: .utf8)
            .split(whereSeparator: \.isNewline).map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
    }
    @MainActor
    private func start(_ owner: Coordinator, root: URL, reviewer: AgentKind = .codex, command: String = "test -f implementation.txt && printf verified > verification.txt", maxCorrections: Int = 0) throws -> Session {
        XCTAssertTrue(owner.startWorkflow(project: Project(name: "Test", path: root.path), agent: .codex,
            reviewer: reviewer, task: "Implement the requirement", verificationCommand: command, maxCorrections: maxCorrections))
        return try XCTUnwrap(owner.sessions.sessions.first)
    }

    @MainActor
    func testThreeStagesRunInOrderWithFreshReadOnlyReviewAndFrozenModels() async throws {
        for reviewer in [AgentKind.codex, .claude] {
            let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
            let owner = try owner(root); defer { owner.stopAll() }
            let session = try start(owner, root: root, reviewer: reviewer)
            owner.settings.settings.codexModel = "changed-model"
            owner.settings.settings.codingModel = "changed-reviewer"
            XCTAssertFalse(owner.followUp(session: session, task: "Bypass the review"))
            try await wait { owner.sessions.session(session.id)?.workflow?.state == .completed }
            let final = try XCTUnwrap(owner.sessions.session(session.id))
            XCTAssertEqual(final.status, .done)
            XCTAssertEqual(final.turns?.map(\.state), [.completed, .completed, .completed])
            XCTAssertEqual(final.workflow?.reviewPassed, true)
            XCTAssertTrue(final.turns?[2].resultText?.contains("codice 0") == true)
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("verification.txt"), encoding: .utf8), "verified")
            let runs = try launches(root)
            XCTAssertEqual(runs.count, 2)
            XCTAssertEqual(runs.map { $0["review"] as? Bool }, [false, true])
            let args = try XCTUnwrap(runs[1]["args"] as? [String])
            XCTAssertFalse(args.contains("resume")); XCTAssertFalse(args.contains("--resume"))
            XCTAssertFalse(args.contains("--dangerously-bypass-approvals-and-sandbox"))
            if reviewer == .codex {
                XCTAssertTrue(args.contains("read-only")); XCTAssertTrue(args.contains("frozen-model"))
                XCTAssertEqual(args.first, "exec")
                XCTAssertTrue(args.contains("--ignore-user-config"))
            } else {
                XCTAssertTrue(args.contains("plan")); XCTAssertTrue(args.contains("Read,Glob,Grep"))
                XCTAssertTrue(args.contains("--strict-mcp-config")); XCTAssertTrue(args.contains("frozen-reviewer"))
            }
            let events = try SessionJournal(url: root.appendingPathComponent("session-events.jsonl")).replay()
            let dispatches = events.filter { $0.kind == .dispatched }
            XCTAssertEqual(dispatches.count, 3)
            XCTAssertTrue(dispatches[1].session.turns?[0].state == .completed)
            XCTAssertTrue(dispatches[2].session.workflow?.reviewPassed == true)
            XCTAssertEqual(SessionStore(root: root).session(session.id)?.workflow?.state, .completed)
        }
    }

    @MainActor
    func testNegativeMissingStaleAndDuplicateReviewsNeverRunVerification() async throws {
        for scenario: [String: Any] in [["verdict": "failed"], ["verdict": "blocked"], ["malformed": true], ["staleToken": true], ["duplicate": true], ["reviewExit": 9]] {
            let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
            let owner = try owner(root, scenario: scenario); defer { owner.stopAll() }
            let session = try start(owner, root: root)
            try await wait { owner.sessions.session(session.id)?.currentTurnID == nil }
            let final = try XCTUnwrap(owner.sessions.session(session.id))
            XCTAssertTrue(final.workflow?.state == .failed || final.workflow?.state == .blocked)
            XCTAssertFalse(final.canResumeQueue)
            XCTAssertFalse(owner.resumePending(sessionID: session.id))
            let verification = try XCTUnwrap(final.turns?.last)
            XCTAssertFalse(owner.spawn(project: Project(name: "Test", path: root.path), agent: .codex,
                task: verification.task, existingID: session.id, queuedTurnID: verification.id))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("verification.txt").path))
            XCTAssertEqual(try launches(root).count, 2)
            XCTAssertEqual(final.turns?.last?.state, .queued)
        }
    }

    @MainActor
    func testImplementationFailurePreventsBothLaterStages() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let owner = try owner(root, scenario: ["implementationExit": 7]); defer { owner.stopAll() }
        let session = try start(owner, root: root)
        try await wait { owner.sessions.session(session.id)?.currentTurnID == nil }
        XCTAssertEqual(try launches(root).count, 1)
        XCTAssertEqual(owner.sessions.session(session.id)?.workflow?.state, .failed)
        XCTAssertFalse(owner.sessions.session(session.id)?.canResumeQueue ?? true)
    }

    @MainActor
    func testVerificationFailureUsesRealExitCodeAndOutput() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let owner = try owner(root); defer { owner.stopAll() }
        let session = try start(owner, root: root, command: "printf 'actual check failed\\n' >&2; exit 17")
        try await wait { owner.sessions.session(session.id)?.currentTurnID == nil }
        let final = try XCTUnwrap(owner.sessions.session(session.id))
        XCTAssertEqual(final.status, .failed)
        XCTAssertEqual(final.workflow?.state, .failed)
        XCTAssertEqual(final.turns?.last?.exitCode, 17)
        XCTAssertTrue(final.resultText.contains("actual check failed"))
        XCTAssertEqual(final.turns?.map(\.state), [.completed, .completed, .failed])
    }

    @MainActor
    func testStopDuringVerificationDoesNotReportWorkflowSuccess() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let owner = try owner(root); defer { owner.stopAll() }
        let session = try start(owner, root: root, command: "/bin/sleep 10; touch should-not-exist.txt", maxCorrections: 2)
        try await wait { owner.sessions.session(session.id)?.turns?.last?.state == .dispatched }
        owner.stop(sessionID: session.id)
        try await wait { owner.sessions.session(session.id)?.currentTurnID == nil }
        XCTAssertEqual(owner.sessions.session(session.id)?.status, .cancelled)
        XCTAssertEqual(owner.sessions.session(session.id)?.workflow?.state, .cancelled)
        XCTAssertEqual(owner.sessions.session(session.id)?.turns?.last?.state, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("should-not-exist.txt").path))
    }

    @MainActor
    func testVerificationTimeoutCannotPassEvenIfProcessCatchesInterruptAndExitsZero() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        var ended = false; var error = false; var output = ""; var outcome: BackendTurnOutcome?
        let backend = VerificationBackend(sessionID: "timeout-test", timeout: .milliseconds(150), onEvent: {
            if case .result(let text, let failure) = $0 { error = failure; output = text }
            if case .turnEnded(let result) = $0 { outcome = result }
        }, onExit: { _, _ in ended = true })
        defer { backend.close() }
        let configuration = AgentExecutionConfiguration(agent: .codex, permissionMode: .acceptEdits)
        try backend.start(AgentRunRequest(executable: "/bin/zsh", task: "trap 'exit 0' INT; /bin/sleep 5", cwd: root.path,
            resume: nil, guidance: nil, configuration: configuration))
        try await wait { ended }
        XCTAssertTrue(error); XCTAssertTrue(output.contains("limite di tempo")); XCTAssertEqual(outcome, .blocked)
    }

    @MainActor
    func testRecoveryCannotSkipAnInterruptedImplementationOrFailedReview() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let config = AgentExecutionConfiguration(agent: .codex, permissionMode: .acceptEdits)
        let implementation = SessionTurn(task: "Build", configuration: config, state: .dispatched, workflowStage: .implementation)
        let review = SessionTurn(task: "Review", configuration: config, workflowStage: .review)
        let check = SessionTurn(task: "false", configuration: config, workflowStage: .verification)
        let original = Session(id: "s_18", projectName: "Test", projectPath: root.path, agent: .codex, task: "Build",
            turns: [implementation, review, check], currentTurnID: implementation.id,
            workflow: AgentWorkflow(originalTask: "Build", verificationCommand: "false", state: .dispatched))
        try SessionStore(root: root).save(original, kind: .dispatched, turnID: implementation.id)
        let recovered = try XCTUnwrap(SessionStore(root: root).session(original.id))
        XCTAssertEqual(recovered.workflow?.state, .interrupted)
        XCTAssertEqual(recovered.turns?.first?.state, .interrupted)
        XCTAssertFalse(recovered.canResumeQueue)
        XCTAssertEqual(recovered.queuedTurns.count, 2)
    }

    @MainActor
    func testCrashBetweenReviewAndVerificationRetainsOnlyExplicitlyResumableVerification() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let owner = try owner(root); defer { owner.stopAll() }
        let configuration = AgentExecutionConfiguration(agent: .codex, permissionMode: .acceptEdits)
        let implementation = SessionTurn(task: "Build", configuration: configuration, state: .completed, workflowStage: .implementation)
        let review = SessionTurn(task: "Review", configuration: configuration, state: .completed, workflowStage: .review)
        let verification = SessionTurn(task: "printf checked > verification.txt", configuration: configuration, workflowStage: .verification)
        let original = Session(id: "s_22", projectName: "Recovery", projectPath: root.path, agent: .codex, task: "Review", status: .done,
            turns: [implementation, review, verification], workflow: AgentWorkflow(originalTask: "Build",
                verificationCommand: verification.task, state: .dispatched, reviewPassed: true))
        try owner.sessions.save(original, kind: .finished, turnID: review.id)
        let restored = try XCTUnwrap(SessionStore(root: root).session(original.id))
        XCTAssertTrue(restored.canResumeQueue)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("verification.txt").path))
        // Verification needs no model CLI or remote context after the review has passed.
        owner.settings.settings.codexPathOverride = "/missing/codex"
        XCTAssertTrue(owner.resumePending(sessionID: original.id))
        try await wait { owner.sessions.session(original.id)?.workflow?.state == .completed }
        XCTAssertEqual(owner.sessions.session(original.id)?.turns?.last?.id, verification.id)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("verification.txt"), encoding: .utf8), "checked")
    }

    func testLegacyModelsDecodeWithoutWorkflowAndReadOnlyFields() throws {
        let session = try JSONDecoder().decode(Session.self, from: Data("{\"id\":\"s_01\",\"projectName\":\"Old\",\"projectPath\":\"/tmp\",\"agent\":\"codex\",\"task\":\"Old\",\"status\":\"done\",\"activity\":\"\",\"startedAt\":0,\"resultText\":\"\",\"dismissed\":false}".utf8))
        XCTAssertNil(session.workflow); XCTAssertNil(session.steering)
        let configuration = try JSONDecoder().decode(AgentExecutionConfiguration.self, from: Data("{\"agent\":\"codex\",\"permissionMode\":\"acceptEdits\"}".utf8))
        XCTAssertNil(configuration.readOnly)
        let project = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(Project(name: "Legacy", path: "/tmp")))
        XCTAssertNil(project.verificationCommand)
    }

    @MainActor
    func testReviewFailureSchedulesFreshCorrectionWithFrozenSettingsAndAtomicJournal() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let owner = try owner(root, scenario: ["reviewSequence": ["failed", "passed"]]); defer { owner.stopAll() }
        XCTAssertTrue(owner.startWorkflow(project: Project(name: "Repair", path: root.path), agent: .codex,
            reviewer: .claude, task: "Implement the requirement", verificationCommand: "test -f corrected.txt"))
        let id = try XCTUnwrap(owner.sessions.sessions.first?.id)
        owner.settings.settings.codexModel = "changed-model"
        owner.settings.settings.codexPermissionMode = .bypassPermissions
        try await wait { owner.sessions.session(id)?.workflow?.state == .completed }
        let final = try XCTUnwrap(owner.sessions.session(id))
        XCTAssertEqual(final.workflow?.correctionLimit, 2)
        XCTAssertEqual(final.workflow?.attempt, 1)
        XCTAssertEqual(final.turns?.map(\.state), [.completed, .failed, .cancelled, .completed, .completed, .completed])
        let turns = try XCTUnwrap(final.turns)
        XCTAssertEqual(turns[3].repairSourceTurnID, turns[1].id)
        XCTAssertEqual(turns[3].configuration, turns[0].configuration)
        XCTAssertEqual(turns[4].configuration, turns[1].configuration)
        XCTAssertTrue(turns[3].task.contains("implementation.txt:1: Incorrect result"))
        XCTAssertTrue(turns[4].task.contains("Review failed:"))
        XCTAssertNotEqual(turns[1].id, turns[4].id)
        XCTAssertFalse(turns[3].task.contains("ORBIT_REVIEW_REPORT:"))
        let runs = try launches(root)
        XCTAssertEqual(runs.map { $0["review"] as? Bool }, [false, true, false, true])
        let args = try XCTUnwrap(runs[2]["args"] as? [String])
        XCTAssertFalse(args.contains("resume")); XCTAssertTrue(args.contains("frozen-model"))
        let journal = try SessionJournal(url: root.appendingPathComponent("session-events.jsonl")).replay()
        let accepted = try XCTUnwrap(journal.firstIndex { $0.kind == .finished && $0.turnID == turns[1].id })
        let dispatch = try XCTUnwrap(journal.firstIndex { $0.kind == .dispatched && $0.turnID == turns[3].id })
        XCTAssertLessThan(accepted, dispatch)
        XCTAssertEqual(journal[accepted].session.turns?.count, 6)
        XCTAssertEqual(journal[accepted].session.workflow?.attempt, 1)
        XCTAssertNil(journal[accepted].session.workflow?.reviewPassed)
    }

    @MainActor
    func testRealVerificationFailureFeedsOutputToCorrectionAndRunsSameCommandAgain() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let owner = try owner(root); defer { owner.stopAll() }
        let command = "test -f corrected.txt || { printf 'actual missing result\\n'; exit 17; }"
        XCTAssertTrue(owner.startWorkflow(project: Project(name: "Repair", path: root.path), agent: .codex,
            reviewer: .codex, task: "Implement the requirement", verificationCommand: command, maxCorrections: 1))
        let id = try XCTUnwrap(owner.sessions.sessions.first?.id)
        try await wait { owner.sessions.session(id)?.workflow?.state == .completed }
        let final = try XCTUnwrap(owner.sessions.session(id)); let turns = try XCTUnwrap(final.turns)
        XCTAssertEqual(turns.map(\.state), [.completed, .completed, .failed, .completed, .completed, .completed])
        XCTAssertEqual(turns[2].exitCode, 17); XCTAssertEqual(turns[5].exitCode, 0)
        XCTAssertTrue(turns[3].task.contains("actual missing result"))
        XCTAssertTrue(turns[3].task.contains("code 17"))
        XCTAssertEqual(turns[3].repairSourceTurnID, turns[2].id)
        XCTAssertEqual(turns[2].task, command); XCTAssertEqual(turns[5].task, command)
        XCTAssertEqual(final.workflow?.attempt, 1)
    }

    @MainActor
    func testRepeatedReviewAndVerificationFailuresStopAtBudgetWithoutQueuedWork() async throws {
        for reviewFailure in [true, false] {
            let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
            let owner = try owner(root, scenario: reviewFailure ? ["verdict": "failed"] : [:]); defer { owner.stopAll() }
            XCTAssertTrue(owner.startWorkflow(project: Project(name: "Repair", path: root.path), agent: .codex,
                reviewer: .codex, task: "Implement", verificationCommand: "printf 'still failing\\n'; exit 1", maxCorrections: 2))
            let id = try XCTUnwrap(owner.sessions.sessions.first?.id)
            try await wait { owner.sessions.session(id)?.workflow?.state == .failed && owner.sessions.session(id)?.currentTurnID == nil }
            let final = try XCTUnwrap(owner.sessions.session(id))
            XCTAssertEqual(final.workflow?.attempt, 2)
            XCTAssertEqual(final.turns?.count, 9); XCTAssertEqual(final.queuedTurns.count, 0)
            XCTAssertEqual(try launches(root).count, 6)
            XCTAssertTrue(final.workflow?.detail.contains("Limite di 2 correzioni raggiunto") == true)
            XCTAssertFalse(final.canResumeQueue); XCTAssertFalse(owner.resumePending(sessionID: id))
            XCTAssertEqual(final.turns?.filter { $0.state == .failed }.count, 3)
        }
    }

    @MainActor
    func testNonActionableReviewsAndInfrastructureFailuresNeverConsumeRepairBudget() async throws {
        for scenario: [String: Any] in [["verdict": "blocked"], ["malformed": true], ["staleToken": true], ["duplicate": true], ["reviewExit": 9], ["implementationExit": 1]] {
            let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
            let owner = try owner(root, scenario: scenario); defer { owner.stopAll() }
            XCTAssertTrue(owner.startWorkflow(project: Project(name: "Repair", path: root.path), agent: .codex,
                reviewer: .codex, task: "Implement", verificationCommand: "true", maxCorrections: 2))
            let id = try XCTUnwrap(owner.sessions.sessions.first?.id)
            try await wait { owner.sessions.session(id)?.currentTurnID == nil }
            let final = try XCTUnwrap(owner.sessions.session(id))
            XCTAssertEqual(final.workflow?.attempt, 0); XCTAssertEqual(final.turns?.count, 3)
            XCTAssertTrue(final.queuedTurns.isEmpty); XCTAssertFalse(final.canResumeQueue)
        }
        for code in [126, 127, 130, 137] {
            let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
            let owner = try owner(root); defer { owner.stopAll() }
            XCTAssertTrue(owner.startWorkflow(project: Project(name: "Repair", path: root.path), agent: .codex,
                reviewer: .codex, task: "Implement", verificationCommand: "exit \(code)", maxCorrections: 2))
            let id = try XCTUnwrap(owner.sessions.sessions.first?.id)
            try await wait { owner.sessions.session(id)?.currentTurnID == nil }
            XCTAssertEqual(owner.sessions.session(id)?.workflow?.attempt, 0)
            XCTAssertEqual(try launches(root).count, 2)
        }
    }

    @MainActor
    func testFailedRepairJournalCannotLaunchCorrection() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let owner = try owner(root, scenario: ["verdict": "failed", "delay": 0.3]); defer { owner.stopAll() }
        XCTAssertTrue(owner.startWorkflow(project: Project(name: "Repair", path: root.path), agent: .codex,
            reviewer: .codex, task: "Implement", verificationCommand: "true", maxCorrections: 2))
        let id = try XCTUnwrap(owner.sessions.sessions.first?.id)
        try await wait { owner.sessions.session(id)?.turns?[1].state == .dispatched }
        let journal = root.appendingPathComponent("session-events.jsonl")
        try FileManager.default.removeItem(at: journal)
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: false)
        try await wait { owner.sessions.session(id)?.currentTurnID == nil }
        XCTAssertEqual(try launches(root).count, 2)
        XCTAssertFalse(owner.sessions.session(id)?.canResumeQueue ?? true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("corrected.txt").path))
    }

    @MainActor
    func testRepairRecoveryRequiresExplicitResumeAndCannotSkipInterruptedCorrection() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let config = AgentExecutionConfiguration(agent: .codex, permissionMode: .acceptEdits)
        let source = SessionTurn(task: "false", configuration: config, state: .failed, workflowStage: .verification)
        var repair = SessionTurn(task: "Repair", configuration: config, workflowStage: .implementation)
        repair.workflowAttempt = 1; repair.repairSourceTurnID = source.id
        var review = SessionTurn(task: "Review", configuration: config, workflowStage: .review); review.workflowAttempt = 1
        var check = SessionTurn(task: "true", configuration: config, workflowStage: .verification); check.workflowAttempt = 1
        var original = Session(id: "s_repair", projectName: "Repair", projectPath: root.path, agent: .codex,
            task: "Build", status: .done, turns: [source, repair, review, check], workflow: AgentWorkflow(originalTask: "Build",
                verificationCommand: "true", state: .dispatched, maxCorrections: 2, correctionsScheduled: 1))
        try SessionStore(root: root).save(original, kind: .finished, turnID: source.id)
        let restored = try XCTUnwrap(SessionStore(root: root).session(original.id))
        XCTAssertTrue(restored.canResumeQueue); XCTAssertEqual(restored.workflow?.attempt, 1)
        XCTAssertEqual(restored.queuedTurns.first?.id, repair.id)
        original.currentTurnID = repair.id; original.status = .running; original.turns?[1].state = .dispatched
        try SessionStore(root: root).save(original, kind: .dispatched, turnID: repair.id)
        let interrupted = try XCTUnwrap(SessionStore(root: root).session(original.id))
        XCTAssertEqual(interrupted.turns?[1].state, .interrupted)
        XCTAssertFalse(interrupted.canResumeQueue)
        XCTAssertEqual(interrupted.workflow?.attempt, 1)
        var stale = restored; stale.turns?[1].state = .completed; stale.turns?[2].state = .completed
        stale.workflow?.reviewPassed = true; stale.turns?[3].workflowAttempt = 0
        XCTAssertFalse(stale.canResumeQueue)
    }

    func testOldWorkflowDefaultsToNoCorrections() throws {
        let workflow = try JSONDecoder().decode(AgentWorkflow.self, from: Data(#"{"originalTask":"Build","verificationCommand":"true","state":"failed","detail":"failed"}"#.utf8))
        XCTAssertEqual(workflow.correctionLimit, 0); XCTAssertEqual(workflow.attempt, 0)
    }

    @MainActor
    func testWorkflowPanelPreviews() throws {
        guard let path = ProcessInfo.processInfo.environment["ORBIT_WORKFLOW_PREVIEW_DIR"] else {
            throw XCTSkip("Set ORBIT_WORKFLOW_PREVIEW_DIR to render workflow states")
        }
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let configuration = AgentExecutionConfiguration(agent: .codex, permissionMode: .acceptEdits, interactiveControls: true)
        let implementation = SessionTurn(task: "Build", configuration: configuration, state: .dispatched, workflowStage: .implementation)
        let review = SessionTurn(task: "Review", configuration: configuration, workflowStage: .review)
        let check = SessionTurn(task: "swift test", configuration: configuration, workflowStage: .verification)
        let working = Session(id: "s_preview", projectName: "Orbit Demo", projectPath: root.path, agent: .codex,
            task: "Aggiungi una pagina prezzi accessibile e verifica i test del progetto.", activity: "Aggiorna la pagina prezzi",
            executionConfiguration: configuration, turns: [implementation, review, check], currentTurnID: implementation.id,
            workflow: AgentWorkflow(originalTask: "Build", verificationCommand: "swift test", state: .dispatched))
        var failed = working
        failed.id = "s_failed"; failed.status = .failed; failed.currentTurnID = nil; failed.finishedAt = Date()
        failed.turns?[0].state = .completed; failed.turns?[0].resultText = "Pagina prezzi aggiunta."
        failed.turns?[1].state = .failed
        failed.workflow?.state = .failed; failed.workflow?.reviewPassed = false
        failed.workflow?.detail = "PricingView.swift:42: manca il nome accessibile del pulsante. Verifica non eseguita."
        let codexConfiguration = AgentExecutionConfiguration(agent: .codex, permissionMode: .acceptEdits, interactiveControls: true)
        var correcting = failed
        correcting.agent = .codex; correcting.executionConfiguration = codexConfiguration
        correcting.id = "s_correcting"; correcting.status = .running; correcting.finishedAt = nil
        correcting.workflow?.state = .dispatched; correcting.workflow?.maxCorrections = 2; correcting.workflow?.correctionsScheduled = 1
        correcting.workflow?.reviewPassed = nil; correcting.workflow?.detail = "Review non superata. Correzione Codex 1 di 2."
        correcting.turns?[2].state = .cancelled
        var repair = SessionTurn(task: "Correggi il nome accessibile del pulsante", configuration: codexConfiguration, state: .dispatched, workflowStage: .implementation)
        repair.workflowAttempt = 1; repair.repairSourceTurnID = review.id
        var reviewAgain = review; reviewAgain.id = UUID(); reviewAgain.workflowAttempt = 1
        var checkAgain = check; checkAgain.id = UUID(); checkAgain.workflowAttempt = 1
        correcting.turns?.append(contentsOf: [repair, reviewAgain, checkAgain]); correcting.currentTurnID = repair.id
        var exhausted = correcting
        exhausted.id = "s_exhausted"; exhausted.status = .failed; exhausted.currentTurnID = nil; exhausted.finishedAt = Date()
        exhausted.turns?[3].state = .completed; exhausted.turns?[4].state = .failed; exhausted.turns?[5].state = .cancelled
        exhausted.workflow?.maxCorrections = 1; exhausted.workflow?.state = .failed
        exhausted.workflow?.detail = "Il controllo di accessibilità fallisce ancora. Limite di 1 correzione raggiunto."
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, session) in [("working", working), ("failed", failed), ("correcting", correcting), ("exhausted", exhausted)] {
            for reduced in [false, true] {
                let content = SessionCard(session: session, now: Date(), onOpen: {}, onLog: {}, onReply: { _ in }, onStop: {}, onDismiss: {})
                    .padding(12).frame(width: 380).haloSurface(radius: 14)
                    .transaction { $0.disablesAnimations = reduced }
                try export(content, directory.appendingPathComponent(name + (reduced ? "-reduced" : "") + ".png"), width: 380, height: 450)
            }
        }
        let owner = try owner(root)
        owner.registry.projects = [Project(name: "Orbit Demo", path: root.path)]
        try export(WorkflowLaunchView(coordinator: owner), directory.appendingPathComponent("launch.png"), width: 578, height: 550)
    }

    @MainActor
    private func export<V: View>(_ content: V, _ destination: URL, width: CGFloat, height: CGFloat) throws {
        let view = NSHostingView(rootView: content)
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view; window.appearance = NSAppearance(named: .darkAqua)
        view.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.2)); view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: destination)
        window.contentView = nil
    }
}
