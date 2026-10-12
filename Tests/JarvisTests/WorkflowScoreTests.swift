import XCTest
@testable import Jarvis

final class WorkflowScoreTests: XCTestCase {
    func testScoreReportsRequireCurrentTokenFiniteScoreAndOneTerminalReport() throws {
        let token = UUID()
        func line(_ score: String = "89.5", verdict: String = "scored", id: UUID? = nil, summary: String = "Evidenza concreta") -> String {
            "ORBIT_SCORE_REPORT: {\"token\":\"\((id ?? token).uuidString)\",\"verdict\":\"\(verdict)\",\"score\":\(score),\"summary\":\"\(summary)\"}"
        }
        XCTAssertEqual(AgentWorkflow.scoreReport(line(), token: token)?.score, 89.5)
        for invalid in [line("101"), line("-1"), line("null"), line("true"), line("\"90\""), line("NaN"), line(id: UUID()), line(summary: " "), line() + "\n" + line(), line() + "\nFurther text", line(verdict: "passed"), line("90", verdict: "blocked")] {
            XCTAssertNil(AgentWorkflow.scoreReport(invalid, token: token), invalid)
        }
        XCTAssertEqual(AgentWorkflow.scoreReport(line("null", verdict: "blocked"), token: token)?.verdict, "blocked")
    }
    func testScoreLoopHasEditableRubricAndIndependentModelsWithoutMandatoryPlan() throws {
        var graph = WorkflowDefinition.scoreLoop
        XCTAssertNil(graph.validationError); XCTAssertFalse(graph.hasPlan); XCTAssertFalse(graph.isDevelopment)
        XCTAssertEqual(graph.node("score")?.failure, "work")
        graph.nodes[0].agent = .claude; graph.nodes[0].model = "worker"
        graph.nodes[1].agent = .codex; graph.nodes[1].model = "judge"
        graph.nodes[1].instructions = "Correttezza 60 punti; copertura dei requisiti 40 punti"
        graph.nodes[1].targetScore = 87.5
        XCTAssertEqual(try JSONDecoder().decode(WorkflowDefinition.self, from: JSONEncoder().encode(graph)), graph)
        graph.nodes[1].targetScore = 101; XCTAssertNotNil(graph.validationError)
        graph.nodes[1].targetScore = 90; graph.nodes[1].instructions = ""; XCTAssertNotNil(graph.validationError)
        XCTAssertFalse(WorkflowNodeKind.evaluation.supportsRepetitions)
        XCTAssertTrue(WorkflowNodeKind.evaluation.usesModel)
        var library = WorkflowLibrary()
        XCTAssertNotNil(library.saveAction(WorkflowNodeKind.evaluation.template))
    }
}
