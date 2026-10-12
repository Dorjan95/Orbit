import Foundation

struct SavedWorkflow: Codable, Hashable, Identifiable, Sendable {
    var id: UUID = UUID()
    var definition: WorkflowDefinition
}

struct SavedWorkflowAction: Codable, Hashable, Identifiable, Sendable {
    var id: UUID = UUID()
    var node: WorkflowNode
}

/// Reusable definitions. Running sessions keep their own immutable graph snapshot.
struct WorkflowLibrary: Codable, Hashable, Sendable {
    var workflows: [SavedWorkflow]
    var defaultID: UUID
    var actions: [SavedWorkflowAction] = []

    init(definition: WorkflowDefinition = .standard) {
        let workflow = SavedWorkflow(definition: definition)
        workflows = [workflow]; defaultID = workflow.id
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        workflows = try c.decode([SavedWorkflow].self, forKey: .workflows)
        defaultID = try c.decode(UUID.self, forKey: .defaultID)
        actions = try c.decodeIfPresent([SavedWorkflowAction].self, forKey: .actions) ?? []
        if workflows.isEmpty { let item = SavedWorkflow(definition: .standard); workflows = [item] }
        if !workflows.contains(where: { $0.id == defaultID }) { defaultID = workflows[0].id }
    }

    var defaultDefinition: WorkflowDefinition {
        get { workflow(defaultID)?.definition ?? workflows.first?.definition ?? .standard }
        set {
            if let index = workflows.firstIndex(where: { $0.id == defaultID }) { workflows[index].definition = newValue }
            else { let item = SavedWorkflow(definition: newValue); workflows.append(item); defaultID = item.id }
        }
    }
    func workflow(_ id: UUID?) -> SavedWorkflow? { workflows.first { $0.id == id } }

    @discardableResult mutating func create(copying id: UUID? = nil) -> UUID {
        var definition = workflow(id)?.definition ?? .empty
        let base = id == nil ? "Nuovo workflow" : definition.name + " — copia"
        definition.name = uniqueName(base)
        let item = SavedWorkflow(definition: definition); workflows.append(item)
        return item.id
    }
    mutating func update(_ id: UUID, definition: WorkflowDefinition) {
        guard let index = workflows.firstIndex(where: { $0.id == id }) else { return }
        workflows[index].definition = definition
    }
    mutating func setDefault(_ id: UUID) {
        if workflow(id) != nil { defaultID = id }
    }
    @discardableResult mutating func remove(_ id: UUID) -> Bool {
        guard workflows.count > 1, workflow(id) != nil else { return false }
        workflows.removeAll { $0.id == id }
        if defaultID == id { defaultID = workflows[0].id }
        return true
    }
    @discardableResult mutating func saveAction(_ node: WorkflowNode) -> UUID? {
        guard node.kind.canSaveAction, node.customConfigurationError == nil else { return nil }
        var template = node
        template.success = nil; template.failure = nil; template.x = 0; template.y = 0
        let item = SavedWorkflowAction(node: template); actions.append(item)
        return item.id
    }
    private func uniqueName(_ base: String) -> String {
        var candidate = base; var suffix = 2
        while workflows.contains(where: { $0.definition.name.localizedCaseInsensitiveCompare(candidate) == .orderedSame }) {
            candidate = base + " \(suffix)"; suffix += 1
        }
        return candidate
    }
}
