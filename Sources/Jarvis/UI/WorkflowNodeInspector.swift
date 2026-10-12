import SwiftUI

struct WorkflowNodeInspector: View {
    @Binding var node: WorkflowNode
    let definition: WorkflowDefinition
    let requiresPlanApproval: Bool
    var disconnect: (WorkflowOutput) -> Void
    var delete: (() -> Void)? = nil
    var saveAction: (() -> Void)? = nil
    @State private var showsNotes = false
    @State private var savedAction = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label(node.kind.label, systemImage: "slider.horizontal.3")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                if let delete {
                    Button("Elimina nodo", systemImage: "trash", role: .destructive, action: delete)
                        .labelStyle(.iconOnly).buttonStyle(.plain).frame(width: 24, height: 24)
                        .help("Elimina questa azione dal workflow")
                }
            }
            TextField("Nome nodo", text: $node.title)
                .font(.system(size: 13, weight: .semibold)).textFieldStyle(.plain)
                .padding(8).background(OrbitDesign.carbon, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(OrbitDesign.line))
            row("Esecuzioni") {
                HStack(spacing: 8) {
                    Text("\(node.maxVisits)").monospacedDigit().fontWeight(.medium)
                    Stepper("Limite esecuzioni", value: $node.maxVisits, in: 1...(node.kind == .correction ? 3 : 10))
                        .labelsHidden().controlSize(.small).fixedSize()
                }
            }.help("Limite totale di visite al nodo, comprese ripetizioni e ritorni dai collegamenti")
            if node.kind == .evaluation {
                row("Score obiettivo") {
                    HStack(spacing: 6) {
                        Text("\(node.resolvedTargetScore, specifier: "%.0f") / 100").monospacedDigit()
                        Stepper("Score obiettivo", value: Binding(get: { node.resolvedTargetScore }, set: { node.targetScore = $0 }), in: 0...100, step: 1).labelsHidden().controlSize(.small).fixedSize()
                    }
                }
                Text("Sotto soglia → collega l’uscita arancione all’attività da ripetere. Imposta il limite di esecuzioni anche sull’attività.").font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if node.kind.supportsRepetitions {
                row("Ripetizioni") {
                    HStack(spacing: 8) {
                        Text("\(node.repetitions ?? 1)").monospacedDigit()
                        Stepper("Ripetizioni", value: Binding(get: { node.repetitions ?? 1 }, set: { node.repetitions = $0; node.maxVisits = max(node.maxVisits, $0) }), in: 1...10)
                            .labelsHidden().controlSize(.small).fixedSize().help("Ripete l’azione dopo ogni esito Riuscito, poi segue il collegamento")
                    }
                }
            }
            Divider().overlay(OrbitDesign.line)
            connection(.success)
            if node.acceptsFailureConnection { connection(.failure) }
            if node.kind.usesModel {
                Divider().overlay(OrbitDesign.line)
                row("Agente") {
                    Picker("Agente", selection: $node.agent) {
                        ForEach(AgentKind.allCases.filter(\.isAvailable)) { Text($0.displayName).tag($0) }
                    }.labelsHidden().controlSize(.small).frame(maxWidth: .infinity)
                }
                row("Modello") {
                    TextField("Predefinito", text: $node.model).textFieldStyle(.roundedBorder)
                        .controlSize(.small).help("Lascia vuoto per usare il modello configurato in Modelli")
                }
            }
            if node.kind.usesActionReport {
                Text(node.kind == .evaluation ? "Criterio di valutazione" : "Istruzioni").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("Descrivi cosa deve fare l’agente…", text: Binding(get: { node.resolvedInstructions }, set: { node.instructions = $0 }), axis: .vertical)
                    .font(.system(size: 11)).textFieldStyle(.plain).lineLimit(4...8)
                    .padding(8).background(OrbitDesign.carbon, in: RoundedRectangle(cornerRadius: 6))
            } else if node.kind == .command {
                Divider().overlay(OrbitDesign.line)
                Text("Comando shell").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("es. swift test", text: $node.command, axis: .vertical)
                    .font(.system(size: 11, design: .monospaced)).textFieldStyle(.plain).lineLimit(3...5)
                    .padding(8).background(OrbitDesign.carbon, in: RoundedRectangle(cornerRadius: 6))
            } else if node.kind == .approval {
                Label(requiresPlanApproval ? "Approvazione manuale" : "Approvazione automatica", systemImage: requiresPlanApproval ? "hand.raised" : "checkmark.circle")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let saveAction {
                Button(savedAction ? "Salvata nel catalogo" : "Salva come azione", systemImage: savedAction ? "checkmark" : "square.and.arrow.down") { saveAction(); savedAction = true }
                    .controlSize(.small).disabled(node.customConfigurationError != nil || savedAction)
                    .help("Crea una copia riutilizzabile nel catalogo Azioni")
            }
            DisclosureGroup("Come funziona", isExpanded: $showsNotes) {
                Text(note + (node.acceptsFailureConnection ? "" : " Blocchi o errori fermano il workflow.")).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 4)
            }.font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(12).background(OrbitDesign.raisedSurface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(OrbitDesign.line))
        .onChange(of: node) { savedAction = false }
        .onChange(of: node.agent) {
            if node.kind == .correction && node.title == "Correzione Codex" { node.title = "Correzione" }
        }
    }
    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            content()
        }.font(.system(size: 11)).frame(minHeight: 24)
    }
    private func connection(_ output: WorkflowOutput) -> some View {
        let target = output.target(in: node)
        let title = definition.node(target)?.title ?? (output == .failure ? "Ferma workflow" : "Concludi")
        return HStack(spacing: 8) {
            Label(node.kind == .evaluation ? (output == .success ? "≥ soglia" : "Sotto soglia") : output.label, systemImage: output == .success ? "checkmark" : "exclamationmark")
                .font(.system(size: 10, weight: .medium)).foregroundStyle(output.color).frame(width: 66, alignment: .leading)
            Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(.secondary)
            Text(title).font(.system(size: 11)).lineLimit(1).help(title)
            Spacer(minLength: 0)
            if target != nil {
                Button { disconnect(output) } label: {
                    Image(systemName: "xmark").font(.system(size: 9)).frame(width: 24, height: 24).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("Scollega " + output.label.lowercased()).help("Scollega " + output.label.lowercased())
            }
        }.frame(minHeight: 24)
    }
    private var note: String {
        switch node.kind {
        case .evaluation: "Valuta in un nuovo contesto e in sola lettura. Orbit confronta il punteggio con la soglia: ≥ soglia segue il verde; sotto soglia segue l’arancione. Senza collegamento arancione il workflow fallisce. Rapporti invalidi o valutazioni bloccate fermano il percorso. Il punteggio è una valutazione del modello secondo il criterio scelto, non una garanzia automatica di qualità."
        case .plan: "Legge il progetto senza modificare file e prepara il Piano. Il modello predefinito è quello configurato in Modelli."
        case .review: "Esegue una review indipendente, in sola lettura e con un nuovo contesto. Il modello predefinito è quello configurato in Modelli."
        case .implementation: "Esegue la richiesta con l’agente scelto, usando il Piano se presente. Il modello predefinito è quello configurato in Modelli."
        case .correction: "L’agente scelto corregge i rilievi del nodo fallito, entro il limite di esecuzioni. Ogni correzione parte in un nuovo contesto. Il modello predefinito è quello configurato in Modelli per quell’agente."
        case .command: "Eseguito nella cartella scelta, con i tuoi permessi, per massimo 5 minuti. Ripetizioni ripete il comando sul successo; Fallito può avviare un altro tentativo entro il limite." + (definition.isDevelopment ? " Dopo il comando servono una nuova review e verifica." : " Nel percorso libero le altre fasi sono opzionali.")
        case .approval: requiresPlanApproval ? "Orbit attende la tua approvazione del Piano prima di proseguire nella sessione." : "Il Piano viene approvato automaticamente e segue l’uscita Riuscito."
        case .verification: "Usa il comando di verifica scelto all’avvio." + (definition.isDevelopment ? " Parte soltanto dopo una review superata." : " Può essere eseguita anche da sola.")
        case .action, .research, .analysis, .testing, .documentation, .summary: node.kind.explanation + " Puoi adattare le istruzioni e scegliere agente e modello. Riuscito e Fallito dipendono dal rapporto dell’agente. Le ripetizioni proseguono sul successo; i collegamenti decidono lo step successivo." + (node.kind == .testing ? " La fase Verifica esegue invece un comando fisso e ne controlla direttamente il codice di uscita." : "") + (definition.isDevelopment ? " Nel modello Sviluppo controllato servono Piano approvato, review e verifica." : " Il percorso libero non richiede altre fasi.")
        }
    }
}
