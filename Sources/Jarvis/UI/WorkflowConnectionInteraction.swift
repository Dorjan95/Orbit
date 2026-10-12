import SwiftUI
import Observation

/// Shared geometry for drawing, pointer targeting and card ports.
enum WorkflowOutput: String, CaseIterable { case success, failure
    var label: String { self == .success ? "Riuscito" : "Fallito" }
    var color: Color { self == .success ? OrbitDesign.lime : .orange }
    func target(in node: WorkflowNode) -> String? { self == .success ? node.success : node.failure }
    func point(on node: WorkflowNode) -> CGPoint { CGPoint(x: node.x + 205, y: node.y + (self == .success ? 44 : 78)) }
}

extension WorkflowNode {
    var acceptsFailureConnection: Bool { [.review, .verification, .command].contains(kind) || kind.usesActionReport }
    var inputPoint: CGPoint { CGPoint(x: x, y: y + 50) }
    var canvasRect: CGRect { CGRect(x: x, y: y, width: 205, height: 100) }
}

@MainActor @Observable
final class WorkflowConnectionInteraction {
    var sourceID: String?
    var output = WorkflowOutput.success
    var pointer: CGPoint?
    var isDragging = false
    var message = ""

    func begin(source: WorkflowNode, output: WorkflowOutput) {
        sourceID = source.id; self.output = output; pointer = output.point(on: source)
        isDragging = false; message = "Trascina verso una card oppure seleziona il suo ingresso. Esc annulla."
    }
    func move(_ point: CGPoint) { guard sourceID != nil else { return }; pointer = point; isDragging = true }
    func cancel() { sourceID = nil; pointer = nil; isDragging = false; message = "" }
    func target(at point: CGPoint, in definition: WorkflowDefinition) -> WorkflowNode? {
        // Ports extend slightly beyond the card; use the same hit area for the preview and drop.
        definition.nodes.reversed().first {
            $0.canvasRect.contains(point) || hypot(point.x - $0.inputPoint.x, point.y - $0.inputPoint.y) <= 22
        }
    }
    func error(for target: WorkflowNode, in definition: WorkflowDefinition) -> String? {
        guard let source = definition.node(sourceID) else { return "Seleziona un'uscita prima dell'ingresso." }
        if output == .failure && !source.acceptsFailureConnection { return "Un errore di \(source.title) ferma il workflow." }
        if definition.isDevelopment && source.kind == .plan && (output != .success || target.kind != .approval) { return "Collega il Piano al nodo Approva piano." }
        return nil
    }
    @discardableResult
    func connect(to targetID: String, in definition: inout WorkflowDefinition) -> Bool {
        guard let target = definition.node(targetID), let index = definition.nodes.firstIndex(where: { $0.id == sourceID }) else { cancel(); return false }
        if let error = error(for: target, in: definition) { cancel(); message = error; return false }
        if output == .success { definition.nodes[index].success = targetID } else { definition.nodes[index].failure = targetID }
        let description = "\(definition.nodes[index].title) · \(output.label) → \(target.title)"
        cancel(); message = description; return true
    }
    func drop(_ point: CGPoint, in definition: inout WorkflowDefinition) {
        guard let target = target(at: point, in: definition) else { cancel(); return }
        connect(to: target.id, in: &definition)
    }
    func disconnect(sourceID: String, output: WorkflowOutput, in definition: inout WorkflowDefinition) {
        guard let index = definition.nodes.firstIndex(where: { $0.id == sourceID }) else { return }
        if output == .success { definition.nodes[index].success = nil } else { definition.nodes[index].failure = nil }
        cancel(); message = "Collegamento \(output.label.lowercased()) scollegato."
    }
}
