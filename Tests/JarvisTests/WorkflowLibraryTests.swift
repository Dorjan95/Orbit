import XCTest
@testable import Jarvis

final class WorkflowLibraryTests: XCTestCase {
    func testExistingWorkflowMigratesWithEveryNodeAndPositionPreserved() throws {
        var graph = WorkflowDefinition.standard
        graph.name = "Il mio percorso"; graph.requiresPlanApproval = false
        graph.nodes[0].agent = .claude; graph.nodes[0].model = "planner"; graph.nodes[0].x = -1800
        _ = graph.insertCustomAction(WorkflowNode(id: "old", kind: .command, title: "Lint", command: "npm run lint", maxVisits: 2, x: 0, y: 0))
        let object: [String: Any] = ["workflowDefinition": try JSONSerialization.jsonObject(with: JSONEncoder().encode(graph)), "codexModel": "keep-model", "handsFree": false]
        let settings = try JSONDecoder().decode(Settings.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(settings.workflowLibrary.workflows.count, 1)
        XCTAssertEqual(settings.workflowDefinition, graph)
        XCTAssertEqual(settings.codexModel, "keep-model"); XCTAssertFalse(settings.handsFree)
        let restored = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(restored.workflowLibrary, settings.workflowLibrary)
    }
    func testIndependentCopiesDefaultsDeletionAndRoundTrip() throws {
        var settings = Settings()
        let first = settings.workflowLibrary.defaultID
        let second = settings.workflowLibrary.create(copying: first)
        var graph = try XCTUnwrap(settings.workflowLibrary.workflow(second)?.definition)
        graph.name = "Claude e test"; graph.nodes[2].agent = .claude
        settings.workflowLibrary.update(second, definition: graph)
        XCTAssertEqual(settings.workflowDefinition, .standard)
        settings.workflowLibrary.setDefault(second)
        XCTAssertEqual(settings.workflowDefinition, graph)
        settings.workflowDefinition.nodes[0].model = "another-planner"
        XCTAssertEqual(settings.workflowLibrary.workflow(second)?.definition.nodes[0].model, "another-planner")
        XCTAssertEqual(settings.workflowLibrary.workflow(first)?.definition, .standard)
        let restored = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(restored.workflowLibrary, settings.workflowLibrary)
        XCTAssertTrue(settings.workflowLibrary.remove(second))
        XCTAssertEqual(settings.workflowLibrary.defaultID, first)
        XCTAssertFalse(settings.workflowLibrary.remove(first))
        settings.workflowLibrary.setDefault(UUID()); XCTAssertEqual(settings.workflowLibrary.defaultID, first)
    }
    func testReusableActionsKeepConfigurationButNeverReuseGraphLinksOrIDs() throws {
        var library = WorkflowLibrary()
        let template = WorkflowNode(id: "source", kind: .action, title: "Documentazione", agent: .claude, model: "doc-model", instructions: "Aggiorna README", success: "foreign-review", failure: "source", maxVisits: 2, x: 1800, y: -800)
        let id = try XCTUnwrap(library.saveAction(template))
        let saved = try XCTUnwrap(library.actions.first { $0.id == id })
        XCTAssertNil(saved.node.success); XCTAssertNil(saved.node.failure)
        var graph = WorkflowDefinition.standard
        let first = try XCTUnwrap(graph.insertCustomAction(saved.node))
        let second = try XCTUnwrap(graph.insertCustomAction(saved.node))
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(graph.node("implementation")?.success, second)
        XCTAssertEqual(graph.node(second)?.success, first); XCTAssertEqual(graph.node(first)?.success, "review")
        XCTAssertEqual(graph.node(second)?.model, "doc-model"); XCTAssertEqual(graph.node(second)?.instructions, "Aggiorna README")
        XCTAssertNil(graph.validationError)
        graph.removeCustomAction(second); XCTAssertEqual(graph.node("implementation")?.success, first)
        graph.removeCustomAction(first); XCTAssertEqual(graph.node("implementation")?.success, "review")
        graph.removeCustomAction("plan"); XCTAssertNotNil(graph.node("plan"))
        XCTAssertEqual(try JSONDecoder().decode(WorkflowLibrary.self, from: JSONEncoder().encode(library)), library)
        XCTAssertNil(library.saveAction(WorkflowDefinition.standard.nodes[0]))
        XCTAssertNil(library.saveAction(WorkflowNode(id: "empty", kind: .action, title: "Empty", x: 0, y: 0)))
    }
    func testNewStandardPhasesHaveEditableDefaultsAndRoundTripAsReusableActions() throws {
        for kind in [WorkflowNodeKind.research, .analysis, .testing, .documentation, .summary] {
            var node = kind.template
            XCTAssertTrue(kind.usesModel); XCTAssertTrue(kind.supportsRepetitions); XCTAssertTrue(node.acceptsFailureConnection)
            XCTAssertFalse(node.resolvedInstructions.isEmpty)
            var graph = WorkflowDefinition.empty
            let id = try XCTUnwrap(graph.insertNode(node)); XCTAssertNil(graph.validationError)
            node.instructions = ""; graph.nodes[0].instructions = ""; XCTAssertNotNil(graph.validationError)
            node.agent = .claude; node.model = "custom-model"; node.instructions = "Istruzioni personali"
            node.success = "foreign"; node.failure = "foreign"
            var library = WorkflowLibrary(); _ = try XCTUnwrap(library.saveAction(node))
            let restored = try JSONDecoder().decode(WorkflowLibrary.self, from: JSONEncoder().encode(library))
            let template = try XCTUnwrap(restored.actions.first?.node)
            XCTAssertEqual(template.agent, .claude); XCTAssertEqual(template.model, "custom-model")
            XCTAssertEqual(template.instructions, "Istruzioni personali"); XCTAssertNil(template.success); XCTAssertNil(template.failure)
            let inserted = try XCTUnwrap(graph.insertNode(template, after: id)); XCTAssertNotEqual(inserted, id)
        }
        var graph = WorkflowDefinition.standard
        graph.nodes[5].agent = .retiredDeepSeek
        XCTAssertNotNil(graph.validationError, "Correction must validate its selected agent just like other AI nodes")
    }
    func testMissingLibraryAndInvalidDefaultHaveUsableFallbacks() throws {
        let old = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
        XCTAssertEqual(old.workflowDefinition, .standard)
        var library = WorkflowLibrary(); library.defaultID = UUID()
        let restored = try JSONDecoder().decode(WorkflowLibrary.self, from: JSONEncoder().encode(library))
        XCTAssertEqual(restored.defaultID, restored.workflows[0].id)
        library.workflows = []
        let empty = try JSONDecoder().decode(WorkflowLibrary.self, from: JSONEncoder().encode(library))
        XCTAssertEqual(empty.workflows.count, 1); XCTAssertEqual(empty.defaultDefinition, .standard)
    }
    func testNewWorkflowsAreEmptyAndAllDefaultNodesCanBeDeletedOrRestored() throws {
        var library = WorkflowLibrary()
        let id = library.create()
        var graph = try XCTUnwrap(library.workflow(id)?.definition)
        XCTAssertEqual(graph.executionMode, .flexible); XCTAssertTrue(graph.nodes.isEmpty)
        XCTAssertNotNil(graph.validationError)
        let action = try XCTUnwrap(graph.insertCustomAction(WorkflowDefinition.research.nodes[0]))
        XCTAssertEqual(graph.entry, action); XCTAssertNil(graph.validationError)
        graph.removeNode(action); XCTAssertTrue(graph.nodes.isEmpty); XCTAssertEqual(graph.entry, "")
        graph = .standard
        for node in graph.nodes { graph.removeNode(node.id) }
        XCTAssertTrue(graph.nodes.isEmpty); XCTAssertEqual(graph.executionMode, .flexible)
        let plan = try XCTUnwrap(graph.insertNode(WorkflowDefinition.standard.nodes[0]))
        XCTAssertEqual(graph.entry, plan); XCTAssertTrue(graph.requiresPlanApproval); XCTAssertNotNil(graph.validationError)
        graph.requiresPlanApproval = false; XCTAssertNil(graph.validationError)
        XCTAssertEqual(try JSONDecoder().decode(WorkflowDefinition.self, from: JSONEncoder().encode(graph)), graph)
        var protected = WorkflowDefinition.standard; protected.nodes.removeAll { $0.kind == .plan }
        XCTAssertNotNil(protected.validationError)
        protected.mode = .flexible; protected.removeNode("approval")
        protected.entry = "implementation"
        XCTAssertNil(protected.validationError)
    }
}
