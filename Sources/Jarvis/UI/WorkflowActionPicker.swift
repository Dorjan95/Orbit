import SwiftUI

extension WorkflowNodeKind {
    var symbol: String {
        switch self {
        case .plan: "list.bullet.clipboard"; case .approval: "hand.raised"; case .implementation: "hammer"
        case .review: "eye"; case .verification: "checkmark.shield"; case .correction: "arrow.triangle.2.circlepath"
        case .command: "terminal"; case .action: "sparkles"
        case .research: "magnifyingglass"; case .analysis: "chart.bar.xaxis"; case .testing: "testtube.2"
        case .documentation: "doc.text"; case .summary: "text.alignleft"; case .evaluation: "gauge.with.dots.needle.67percent"
        }
    }
}

enum WorkflowActionCategory: String, CaseIterable, Identifiable {
    case standard = "Fasi standard", custom = "Azioni personalizzate"
    var id: String { rawValue }
}

private struct WorkflowPhaseGroup: Identifiable {
    let id: String
    let kinds: [WorkflowNodeKind]
    static let all = [
        Self(id: "Esplorazione e risultati", kinds: [.research, .analysis, .summary, .evaluation]),
        Self(id: "Sviluppo e controllo", kinds: [.plan, .approval, .implementation, .testing, .review, .verification, .correction, .documentation])
    ]
}

struct WorkflowActionPicker: View {
    let definition: WorkflowDefinition
    var library: Binding<WorkflowLibrary>?
    var select: (String) -> Void
    var add: (WorkflowNode) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var category: WorkflowActionCategory

    init(definition: WorkflowDefinition, library: Binding<WorkflowLibrary>?, initialCategory: WorkflowActionCategory = .custom, select: @escaping (String) -> Void, add: @escaping (WorkflowNode) -> Void) {
        self.definition = definition; self.library = library; self.select = select; self.add = add
        _category = State(initialValue: initialCategory)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Azioni del workflow").font(.title3.bold())
                Spacer()
                Button("Chiudi", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly).buttonStyle(.plain).frame(width: 24, height: 24)
            }
            TextField("Cerca un’azione", text: $query).textFieldStyle(.roundedBorder)
            Picker("Tipo di azioni", selection: $category) {
                ForEach(WorkflowActionCategory.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if category == .standard {
                        section("Fasi standard", detail: "Sono opzionali nei percorsi liberi. Aggiungi quelle che servono oppure configura un nodo già presente.")
                        let kinds = WorkflowNodeKind.allCases.filter { !$0.isCustom && matches($0.label) }
                        if kinds.isEmpty { Text("Nessuna fase corrisponde alla ricerca.").font(.caption).foregroundStyle(.secondary) }
                        ForEach(WorkflowPhaseGroup.all) { group in
                            let visible = group.kinds.filter { matches($0.label) }
                            if !visible.isEmpty {
                                Text(group.id).font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                                ForEach(visible) { kind in standardPhase(kind) }
                            }
                        }
                    } else {
                        section("Crea un’azione", detail: definition.isDevelopment ? "Inserita dopo Implementazione. Puoi ricollegarla nel canvas." : "Inserita dopo il nodo selezionato. Il primo nodo diventa l’inizio del percorso.")
                        ForEach([WorkflowNodeKind.action, .command].filter { matches($0.label) }) { kind in
                            actionRow(kind.label, detail: kind.explanation, symbol: kind.symbol, button: "Aggiungi") {
                                add(kind.template); dismiss()
                            }.disabled(definition.nodes.count >= 20)
                        }
                        Divider().padding(.vertical, 4)
                        section("Le tue azioni", detail: "Salvale dal pannello del nodo per riutilizzarle in qualsiasi workflow.")
                        if let library {
                            let actions = library.wrappedValue.actions.filter { matches($0.node.title + " " + $0.node.kind.label) }
                            if actions.isEmpty { Text(query.isEmpty ? "Nessuna azione salvata." : "Nessuna azione salvata corrisponde alla ricerca.").font(.caption).foregroundStyle(.secondary) }
                            ForEach(actions) { item in
                                HStack {
                                    actionRow(item.node.title, detail: item.node.kind.usesModel ? item.node.agent.displayName + " · " + item.node.resolvedInstructions : item.node.command, symbol: item.node.kind.symbol, button: "Aggiungi") { add(item.node); dismiss() }.disabled(definition.nodes.count >= 20)
                                    Button("Rimuovi dal catalogo", systemImage: "trash", role: .destructive) {
                                        library.wrappedValue.actions.removeAll { $0.id == item.id }
                                    }.labelStyle(.iconOnly).buttonStyle(.plain).frame(width: 24, height: 24).help("Rimuovi dal catalogo; i nodi già inseriti restano nel workflow")
                                }
                            }
                        }
                    }
                }.padding(.trailing, 4)
            }
        }.padding(20).frame(width: 500, height: 610)
            .background(OrbitDesign.screen).foregroundStyle(OrbitDesign.chalk).tint(OrbitDesign.lime).preferredColorScheme(.dark)
    }
    private func matches(_ text: String) -> Bool { query.isEmpty || text.localizedCaseInsensitiveContains(query) }
    private func standardPhase(_ kind: WorkflowNodeKind) -> some View {
        let existing = definition.nodes.first { $0.kind == kind }
        return actionRow(existing?.title ?? kind.label, detail: kind.explanation, symbol: kind.symbol, button: existing == nil ? "Aggiungi" : "Configura") {
            if let existing { select(existing.id) } else { add(kind.template) }
            dismiss()
        }.disabled(existing == nil && definition.nodes.count >= 20)
    }
    private func section(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(title).font(.headline); Text(detail).font(.caption).foregroundStyle(.secondary) }
    }
    private func actionRow(_ title: String, detail: String, symbol: String, button: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).frame(width: 20).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).help(detail).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(button, action: action).controlSize(.small)
        }.padding(10).background(OrbitDesign.raisedSurface, in: RoundedRectangle(cornerRadius: 8))
    }
}
