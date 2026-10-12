import SwiftUI

private struct WorkflowEditorSelection: Identifiable {
    var id: UUID
    var nodeID: String?
}

struct WorkflowLibraryView: View {
    @Binding var library: WorkflowLibrary
    @State private var selection: UUID?
    @State private var editor: WorkflowEditorSelection?
    @State private var confirmingDelete = false

    private var selected: SavedWorkflow { library.workflow(selection) ?? library.workflow(library.defaultID) ?? library.workflows[0] }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("I tuoi workflow").font(.title3.bold())
                Text("Crea percorsi diversi e scegli quale usare per ogni lavoro. Il predefinito viene proposto all’avvio ed è usato per le richieste a voce.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Picker("Workflow", selection: Binding(get: { selected.id }, set: { selection = $0 })) {
                    ForEach(library.workflows) { item in
                        Text(item.definition.name + (item.id == library.defaultID ? " · predefinito" : "")).tag(item.id)
                    }
                }
            }
            HStack {
                Button("Nuovo", systemImage: "plus") { selection = library.create(); editor = WorkflowEditorSelection(id: selected.id) }
                Button("Duplica", systemImage: "doc.on.doc") { selection = library.create(copying: selected.id); editor = WorkflowEditorSelection(id: selected.id) }
                Spacer()
                Button("Elimina", systemImage: "trash", role: .destructive) { confirmingDelete = true }.disabled(library.workflows.count <= 1)
            }
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(selected.definition.name).font(.headline)
                    Spacer()
                    if selected.id == library.defaultID {
                        Label("Predefinito", systemImage: "star.fill").font(.caption).foregroundStyle(OrbitDesign.lime)
                    } else {
                        Button("Usa come predefinito", systemImage: "star") { library.setDefault(selected.id) }.controlSize(.small)
                    }
                }
                Label(selected.definition.hasPlan ? (selected.definition.requiresPlanApproval ? "Il Piano richiede approvazione" : "Il Piano prosegue automaticamente") : "Percorso libero · nessun Piano richiesto", systemImage: selected.definition.hasPlan ? "hand.raised" : "arrow.triangle.branch")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Apri editor visuale", systemImage: "point.3.connected.trianglepath.dotted") { editor = WorkflowEditorSelection(id: selected.id) }.buttonStyle(.borderedProminent)
                Divider()
                Text("Azioni in questo workflow").font(.caption).foregroundStyle(.secondary)
                Text("Seleziona una fase per configurarla. Nell’editor, Azioni apre il catalogo delle fasi standard e delle tue azioni riutilizzabili.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(selected.definition.nodes) { node in
                    Button { editor = WorkflowEditorSelection(id: selected.id, nodeID: node.id) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: node.kind.symbol).frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(node.title).fontWeight(.medium)
                                Text(node.kind.isCustom ? node.kind.label : "Fase standard").font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(node.kind.usesModel ? node.agent.displayName + (node.model.isEmpty ? " · predefinito" : " · " + node.model) : "Max \(node.maxVisits) esecuzioni")
                                .foregroundStyle(.secondary).lineLimit(1)
                            Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.secondary)
                        }.font(.system(size: 12)).padding(.vertical, 6).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                if selected.definition.nodes.isEmpty { Text("Workflow vuoto. Apri l’editor e aggiungi la prima azione, oppure scegli un modello di partenza.").font(.caption).foregroundStyle(.secondary) }
            }.padding(16).background(OrbitDesign.raisedSurface, in: RoundedRectangle(cornerRadius: 10))
            Text("I workflow salvati sono modelli riutilizzabili. Le modifiche riguardano i nuovi lavori: le sessioni già avviate mantengono la propria configurazione.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .sheet(item: $editor) { item in
            WorkflowEditorView(definition: Binding(get: { library.workflow(item.id)?.definition ?? .standard }, set: { library.update(item.id, definition: $0) }), library: $library, selectedNode: item.nodeID)
        }
        .alert("Eliminare \(selected.definition.name)?", isPresented: $confirmingDelete) {
            Button("Annulla", role: .cancel) {}
            Button("Elimina", role: .destructive) { _ = library.remove(selected.id); selection = library.defaultID }
        } message: { Text("Le sessioni già avviate conserveranno il workflow. Se elimini il predefinito, Orbit ne sceglierà un altro dalla raccolta.") }
    }
}
