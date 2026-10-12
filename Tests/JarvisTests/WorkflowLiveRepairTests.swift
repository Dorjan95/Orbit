import XCTest
@testable import Jarvis

/// Opt-in provider validation. A deliberately broken fixture seeds the failure;
/// review, correction and repeated verification use the real production runtime.
final class WorkflowLiveRepairTests: XCTestCase {
    @MainActor func testRealCodexRepairsReviewAndVerificationFailures() async throws {
        guard let path = ProcessInfo.processInfo.environment["ORBIT_REPAIR_LIVE_DIR"] else {
            throw XCTSkip("Set ORBIT_REPAIR_LIVE_DIR to run real Codex repairs using the existing CLI login")
        }
        let executable = try XCTUnwrap(CLILocator.find("codex"))
        let evidence = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        for failure in ["review", "verification"] {
            let root = evidence.appendingPathComponent(failure + "-" + UUID().uuidString)
            let workspace = root.appendingPathComponent("workspace")
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            try Data("def answer():\n    return 0\n".utf8).write(to: workspace.appendingPathComponent("answer.py"))
            let testSource = "import unittest\nfrom answer import answer\n\nclass AnswerTests(unittest.TestCase):\n    def test_answer(self):\n        self.assertEqual(answer(), 42)\n"
            try Data(testSource.utf8).write(to: workspace.appendingPathComponent("test_answer.py"))
            // Review must be able to prove that tests stayed unchanged, not guess.
            let git = try XCTUnwrap(CLILocator.find("git"))
            for args in [["init", "-q"], ["add", "--", "answer.py", "test_answer.py"],
                         ["-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false",
                          "-c", "user.name=Orbit Test", "-c", "user.email=orbit-test@localhost",
                          "commit", "-qm", "Controlled fixture baseline"]] {
                let result = await CLILocator.run(git, args, cwd: workspace.path, timeout: 10)
                XCTAssertEqual(result.code, 0, result.stderr)
            }
            let owner = Coordinator(enableServices: false, sessionRoot: root)
            defer { owner.stopAll() }
            owner.settings.settings = Settings()
            owner.settings.settings.codexPathOverride = executable
            owner.settings.settings.codexModel = ""
            owner.settings.settings.speakSummaries = false; owner.settings.settings.openResults = false
            let config = AgentExecutionConfiguration(agent: .codex, permissionMode: .acceptEdits,
                codex: owner.settings.settings.workerBackend, readOnly: false, interactiveControls: true)
            var reviewConfig = config; reviewConfig.readOnly = true; reviewConfig.interactiveControls = false
            let task = "Fix answer.py so answer() returns the integer 42. Keep test_answer.py unchanged. Work only in this workspace. Orbit runs review and verification; do not operate Orbit or start other workflows."
            let command = "python3 -m unittest -v test_answer"
            let implementation = SessionTurn(task: task, configuration: config, state: .completed,
                workflowStage: .implementation, resultText: "Controlled test fixture: answer.py still returns 0.")
            var review = SessionTurn(task: "Review", configuration: reviewConfig,
                state: failure == "review" ? .queued : .completed, workflowStage: .review)
            review.task = AgentWorkflow.reviewTask(task: task, implementation: implementation.resultText!, token: review.id)
            if failure == "verification" {
                review.resultText = "Seeded gate for controlled verification failure; this initial review is a fixture."
            }
            let verification = SessionTurn(task: command, configuration: config, workflowStage: .verification)
            let session = Session(id: owner.sessions.nextID(), projectName: "CodexRepair-" + failure, projectPath: workspace.path,
                agent: .codex, task: task, status: .done, turns: [implementation, review, verification],
                workflow: AgentWorkflow(originalTask: task, verificationCommand: command, state: .dispatched,
                    reviewPassed: failure == "verification" ? true : nil, maxCorrections: 1, correctionsScheduled: 0))
            try owner.sessions.save(session, kind: .accepted)
            XCTAssertTrue(owner.resumePending(sessionID: session.id))
            let deadline = Date().addingTimeInterval(240)
            while owner.sessions.session(session.id)?.currentTurnID != nil && Date() < deadline {
                if let pending = owner.sessions.session(session.id)?.pendingApprovals.first {
                    XCTFail("Unexpected interactive approval requires human input: \(pending.title)")
                    owner.stop(sessionID: session.id); break
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            let final = try XCTUnwrap(owner.sessions.session(session.id))
            try JSONEncoder().encode(final).write(to: root.appendingPathComponent("result.json"))
            XCTAssertNil(final.currentTurnID, final.resultText)
            XCTAssertEqual(final.workflow?.state, .completed, final.workflow?.detail ?? final.resultText)
            XCTAssertEqual(final.workflow?.attempt, 1)
            XCTAssertEqual(final.turns?.count, 6)
            XCTAssertEqual(final.turns?[failure == "review" ? 1 : 2].state, .failed)
            XCTAssertEqual(final.turns?.suffix(3).map(\.state), [.completed, .completed, .completed])
            XCTAssertEqual(final.turns?.last?.exitCode, 0)
            let correctedReview = try XCTUnwrap(final.turns?[4])
            XCTAssertEqual(AgentWorkflow.reviewReport(correctedReview.resultText ?? "", token: correctedReview.id)?.verdict, "passed")
            XCTAssertEqual(try String(contentsOf: workspace.appendingPathComponent("test_answer.py"), encoding: .utf8), testSource)
            XCTAssertTrue(final.turns?[3].configuration.supportsInteractiveControls == true)
            XCTAssertEqual(final.turns?[3].configuration.permissionMode, .acceptEdits)
            print("LIVE_REPAIR_EVIDENCE: \(root.path)")
        }
    }
}
