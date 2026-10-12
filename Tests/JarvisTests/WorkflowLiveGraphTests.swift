import XCTest
@testable import Jarvis

final class WorkflowLiveGraphTests: XCTestCase {
    @MainActor func testRealCodexPlansWaitsImplementsReviewsAndVerifies() async throws {
        guard let path = ProcessInfo.processInfo.environment["ORBIT_GRAPH_LIVE_DIR"] else { throw XCTSkip("Optional real Codex graph validation") }
        let root = URL(fileURLWithPath: path).appendingPathComponent(UUID().uuidString)
        let workspace = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let testSource = "import unittest\nfrom answer import answer\n\nclass AnswerTests(unittest.TestCase):\n    def test_answer(self):\n        self.assertEqual(answer(), 42)\n"
        try Data("def answer():\n    return 0\n".utf8).write(to: workspace.appendingPathComponent("answer.py"))
        try Data(testSource.utf8).write(to: workspace.appendingPathComponent("test_answer.py"))
        let git = try XCTUnwrap(CLILocator.find("git"))
        for args in [["init", "-q"], ["add", "--", "answer.py", "test_answer.py"], ["-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", "-c", "user.name=Orbit Test", "-c", "user.email=orbit-test@localhost", "commit", "-qm", "Controlled graph fixture"]] {
            let result = await CLILocator.run(git, args, cwd: workspace.path, timeout: 10); XCTAssertEqual(result.code, 0, result.stderr)
        }
        let owner = Coordinator(enableServices: false, sessionRoot: root); defer { owner.stopAll() }
        owner.settings.settings = Settings()
        owner.settings.settings.codexPathOverride = try XCTUnwrap(CLILocator.find("codex"))
        owner.settings.settings.speakSummaries = false; owner.settings.settings.openResults = false
        let project = Project(name: "LiveGraph", path: workspace.path, defaultAgent: .codex, permissionMode: .acceptEdits)
        XCTAssertTrue(owner.startWorkflow(project: project, agent: .codex, reviewer: .codex,
            task: "Fix answer.py so answer() returns the integer 42. Keep test_answer.py unchanged. Work only in this workspace. Orbit manages approvals, review and verification: do not open Orbit or start other workflows.",
            verificationCommand: "python3 -m unittest -v test_answer", definition: .standard))
        let id = try XCTUnwrap(owner.sessions.sessions.first?.id)
        let deadline = Date().addingTimeInterval(240)
        while owner.sessions.session(id)?.currentTurnID != nil && Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        let planned = try XCTUnwrap(owner.sessions.session(id))
        try JSONEncoder().encode(planned).write(to: root.appendingPathComponent("planned.json"))
        XCTAssertEqual(planned.workflow?.awaitingPlanApproval, true, planned.workflow?.detail ?? planned.resultText)
        XCTAssertEqual(planned.turns?.count, 1)
        XCTAssertEqual(try String(contentsOf: workspace.appendingPathComponent("answer.py"), encoding: .utf8), "def answer():\n    return 0\n")
        guard owner.decidePlan(sessionID: id, approve: true) else { XCTFail("Plan approval did not start implementation"); return }
        while owner.sessions.session(id)?.currentTurnID != nil && Date() < deadline {
            if let approval = owner.sessions.session(id)?.pendingApprovals.first {
                XCTFail("Unexpected tool approval needs human input: \(approval.title)"); owner.stop(sessionID: id); break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let final = try XCTUnwrap(owner.sessions.session(id))
        try JSONEncoder().encode(final).write(to: root.appendingPathComponent("result.json"))
        XCTAssertEqual(final.workflow?.state, .completed, final.workflow?.detail ?? final.resultText)
        XCTAssertEqual(final.turns?.prefix(4).map(\.workflowStage), [.planning, .implementation, .review, .verification])
        XCTAssertEqual(final.turns?.last?.exitCode, 0)
        XCTAssertEqual(try String(contentsOf: workspace.appendingPathComponent("test_answer.py"), encoding: .utf8), testSource)
        print("LIVE_GRAPH_EVIDENCE: \(root.path)")
    }
}
