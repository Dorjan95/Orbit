import SwiftUI

struct WorkflowProgressView: View {
    let session: Session
    var onPlanDecision: (Bool) -> Void = { _ in }
    @State private var planExpanded = true
    @State private var expandedTurnID: UUID?
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let plan = session.workflow?.plan {
                DisclosureGroup(session.workflow?.awaitingPlanApproval == true ? "Piano da approvare" : "Piano del workflow", isExpanded: $planExpanded) {
                    ScrollView { Text(plan.text).font(.system(size: 12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 230)
                }.font(.system(size: 12, weight: .semibold))
                if session.workflow?.awaitingPlanApproval == true {
                    HStack {
                        Button("Rifiuta piano") { onPlanDecision(false) }
                        Spacer()
                        Button(session.workflow?.definition?.isDevelopment == false ? "Approva e prosegui" : "Approva e implementa") { onPlanDecision(true) }.buttonStyle(.borderedProminent)
                    }.controlSize(.small)
                }
            }
            let attempt = session.workflow?.attempt ?? 0
            if let workflow = session.workflow, workflow.correctionLimit > 0 {
                let correctionAgent = workflow.definition?.nodes.first(where: { $0.kind == .correction })?.agent.displayName ?? "Codex"
                Text(attempt == 0 ? "Tentativo iniziale · fino a \(workflow.correctionLimit) correzioni con \(correctionAgent)" : "Correzione con \(correctionAgent) \(attempt) di \(workflow.correctionLimit)")
                    .font(.system(size: 11, weight: .semibold))
            }
            if session.workflow?.definition != nil { graphStages(attempt: attempt) }
            else { stages(attempt: attempt) }
            if attempt > 0 {
                DisclosureGroup("Tentativi precedenti (\(attempt))") {
                    ForEach(0..<attempt, id: \.self) { previous in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(previous == 0 ? "Tentativo iniziale" : "Correzione \(previous)")
                                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                            if session.workflow?.definition != nil { graphStages(attempt: previous) }
                            else { stages(attempt: previous) }
                        }.padding(.vertical, 6)
                    }
                }.font(.system(size: 11))
            }
            if let workflow = session.workflow {
                if let scores = workflow.scoreResults, !scores.isEmpty {
                    DisclosureGroup("Score \(scores.last!.score.formatted()) / 100 · obiettivo \(scores.last!.target.formatted()) · \(scores.count) valutazioni") {
                        ForEach(scores, id: \.turnID) { result in
                            VStack(alignment: .leading, spacing: 3) {
                                Text((workflow.definition?.node(result.nodeID)?.title ?? "Valutazione") + " · " + result.score.formatted() + " / 100").fontWeight(.medium)
                                Text(result.summary).textSelection(.enabled)
                            }.font(.system(size: 11)).padding(.vertical, 4)
                        }
                    }.font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if workflow.definition?.usesVerification != false && !workflow.verificationCommand.isEmpty {
                    Text(workflow.verificationCommand).font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                }
                if !workflow.detail.isEmpty {
                    Text(workflow.detail).font(.system(size: 11)).lineLimit(4).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
        }
        .padding(9).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }
    @ViewBuilder private func graphStages(attempt: Int) -> some View {
        if let graph = session.workflow?.definition {
            ForEach(graph.nodes.filter { node in
                if node.kind == .approval { return attempt == 0 }
                return session.turns?.contains(where: { $0.workflowNodeID == node.id && ($0.workflowAttempt ?? 0) == attempt }) == true || (attempt == 0 && node.kind != .correction)
            }) { node in
                let turn = session.turns?.last(where: { $0.workflowNodeID == node.id && ($0.workflowAttempt ?? 0) == attempt })
                if node.kind == .approval {
                    HStack(spacing: 7) {
                        Image(systemName: session.workflow?.planApproved == true ? "checkmark.circle.fill" : "hand.raised")
                        Text(node.title).font(.system(size: 11, weight: .medium)); Spacer()
                        Text(session.workflow?.planApproved == true ? "Approvato" : "In attesa").font(.system(size: 10))
                    }.foregroundStyle(session.workflow?.planApproved == true ? OrbitDesign.lime : OrbitDesign.secondaryText).frame(minHeight: 28)
                } else if let stage = node.kind.stage {
                    Button { expandedTurnID = expandedTurnID == turn?.id ? nil : turn?.id } label: {
                        stageRow(stage, turn: turn, title: node.title + ((session.workflow?.nodeVisits?[node.id] ?? 0) > 1 ? " · \(session.workflow?.nodeVisits?[node.id] ?? 0)/\(node.maxVisits)" : ""))
                    }.buttonStyle(.plain).disabled(turn?.resultText?.isEmpty != false)
                    if let turn, expandedTurnID == turn.id, let text = turn.resultText {
                        ScrollView { Text(readableResult(text, turn: turn)).font(.system(size: 11)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 140)
                    }
                }
            }
        }
    }
    @ViewBuilder private func stages(attempt: Int) -> some View {
        ForEach(WorkflowStage.allCases.filter { stage in session.turns?.contains(where: { $0.workflowStage == stage }) == true }, id: \.self) { stage in
            let turn = session.turns?.last(where: { $0.workflowStage == stage && ($0.workflowAttempt ?? 0) == attempt })
            if turn?.resultText?.isEmpty == false {
                Button { expandedTurnID = expandedTurnID == turn?.id ? nil : turn?.id } label: { stageRow(stage, turn: turn) }
                    .buttonStyle(.plain).help("Mostra o nascondi il risultato della fase")
            } else { stageRow(stage, turn: turn) }
            if let turn, expandedTurnID == turn.id, let text = turn.resultText {
                ScrollView {
                    Text(readableResult(text, turn: turn)).font(.system(size: 11)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 140)
            }
        }
    }
    private func stageRow(_ stage: WorkflowStage, turn: SessionTurn?, title: String? = nil) -> some View {
        let state = turn?.state ?? .queued
        return HStack(spacing: 7) {
            Image(systemName: symbol(state)).foregroundStyle(color(state)).frame(width: 14)
            Text(title ?? stage.label).font(.system(size: 11, weight: .medium))
            Spacer()
            Text(label(state)).font(.system(size: 10)).foregroundStyle(OrbitDesign.secondaryText)
            if turn?.resultText?.isEmpty == false {
                Image(systemName: expandedTurnID == turn?.id ? "chevron.up" : "chevron.down").font(.system(size: 9))
            }
        }.frame(minHeight: 28).contentShape(Rectangle()).accessibilityElement(children: .combine)
    }
    private func readableResult(_ text: String, turn: SessionTurn) -> String {
        if turn.workflowStage == .planning, let plan = AgentWorkflow.planReport(text, token: turn.id) { return plan.text }
        if turn.workflowStage == .review, let report = AgentWorkflow.reviewReport(text, token: turn.id) {
            return ([report.summary] + report.findings).joined(separator: "\n")
        }
        if turn.workflowStage == .action, let report = AgentWorkflow.scoreReport(text, token: turn.id) {
            return "Score: " + (report.score?.formatted() ?? "non disponibile") + "/100. " + report.summary
        }
        if turn.workflowStage == .action, let report = AgentWorkflow.actionReport(text, token: turn.id) {
            let body = text.split(whereSeparator: \.isNewline).filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("ORBIT_ACTION_REPORT:") }.joined(separator: "\n")
            return body.isEmpty ? report.summary : body
        }
        return text
    }
    private func symbol(_ state: TurnState) -> String {
        switch state {
        case .completed: "checkmark.circle.fill"
        case .dispatched: "arrow.trianglehead.2.clockwise.rotate.90"
        case .queued: "circle"
        case .blocked: "hand.raised.fill"
        case .failed, .interrupted: "exclamationmark.circle.fill"
        case .cancelled: "xmark.circle"
        }
    }
    private func color(_ state: TurnState) -> Color {
        switch state { case .completed, .dispatched: OrbitDesign.lime; case .failed, .blocked, .interrupted: .orange; default: .secondary }
    }
    private func label(_ state: TurnState) -> String {
        switch state {
        case .completed: "Superata"
        case .dispatched: "In corso"
        case .queued: "In attesa"
        case .failed: "Non superata"
        case .blocked: "Bloccata"
        case .cancelled: "Annullata"
        case .interrupted: "Interrotta"
        }
    }
}

struct WorkflowLaunchView: View {
    @Bindable var coordinator: Coordinator
    @Environment(\.dismiss) private var dismiss
    @State private var projectID: UUID?
    @State private var task = ""
    @State private var command = ""
    @State private var error = ""
    @State private var definition = WorkflowDefinition.standard
    @State private var editingWorkflow = false
    @State private var workflowID: UUID?
    @State private var initialized = false

    private var project: Project? { coordinator.registry.projects.first(where: { $0.id == projectID }) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Nuovo workflow").font(.title2.bold())
            Text(definition.isDevelopment ? "Orbit segue Piano, approvazione, sviluppo e controlli." : "Orbit esegue soltanto le azioni del percorso scelto, a partire dal nodo iniziale. Puoi fare ricerca, ripetere un’azione o eseguire comandi senza un Piano.")
                .font(.callout).foregroundStyle(.secondary)
            Form {
                Picker("Progetto", selection: $projectID) {
                    Text("Generale · senza progetto").tag(Optional<UUID>.none)
                    ForEach(coordinator.registry.projects) { Text($0.name).tag(Optional($0.id)) }
                }
                Picker("Workflow salvato", selection: $workflowID) {
                    ForEach(coordinator.settings.settings.workflowLibrary.workflows) { item in
                        Text(item.definition.name + (item.id == coordinator.settings.settings.workflowLibrary.defaultID ? " · predefinito" : "")).tag(Optional(item.id))
                    }
                }
                LabeledContent("Inizio", value: definition.node(definition.entry)?.title ?? "Nessun nodo")
                if definition.hasPlan {
                    LabeledContent("Piano", value: definition.nodes.first(where: { $0.kind == .plan }).map { $0.agent.displayName + ($0.model.isEmpty ? " · modello configurato" : " · " + $0.model) } ?? "")
                    LabeledContent("Approvazione", value: definition.requiresPlanApproval ? "Richiesta" : "Automatica")
                }
                Button("Adatta per questo lavoro…", systemImage: "point.3.connected.trianglepath.dotted") { editingWorkflow = true }
                TextField("Richiesta", text: $task, axis: .vertical).lineLimit(3...6)
                if definition.usesVerification { TextField("Comando di verifica", text: $command).font(.system(.body, design: .monospaced)) }
            }
            Text("Le modifiche qui valgono solo per questo lavoro. Gestisci i workflow salvati in Impostazioni → Workflow.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Le azioni AI usano gli accessi e i modelli configurati in Orbit. I comandi operano nella cartella scelta. Ripetizioni e cicli rispettano i limiti dei nodi e un massimo totale di 64 passaggi; blocchi ed errori delle CLI fermano il lavoro.")
                .font(.caption).foregroundStyle(.secondary)
            if !error.isEmpty { Text(error).font(.callout).foregroundStyle(.orange) }
            if let problem = definition.validationError { Text(problem).font(.caption).foregroundStyle(.orange) }
            HStack {
                Button("Annulla") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(definition.node(definition.entry)?.kind == .plan ? "Genera piano" : "Avvia workflow") {
                    guard let project = project ?? coordinator.generalProject() else { error = "Non riesco ad aprire l’area Generale."; return }
                    if coordinator.startWorkflow(project: project, agent: definition.nodes.first(where: { $0.kind == .implementation })?.agent ?? .codex, reviewer: definition.nodes.first(where: { $0.kind == .review })?.agent ?? .codex, task: task, verificationCommand: command, definition: definition) {
                        if definition.usesVerification { var updated = project; updated.verificationCommand = command; coordinator.registry.update(updated) }
                        dismiss()
                    } else { error = "Avvio non riuscito. Controlla le CLI configurate e la disponibilità del progetto." }
                }
                .disabled(definition.validationError != nil || task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (definition.usesVerification && command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }
        .padding(24).frame(width: 530)
        .background(OrbitDesign.screen).foregroundStyle(OrbitDesign.chalk).tint(OrbitDesign.lime).preferredColorScheme(.dark)
        .sheet(isPresented: $editingWorkflow) { WorkflowEditorView(definition: $definition, library: Binding(get: { coordinator.settings.settings.workflowLibrary }, set: { coordinator.settings.settings.workflowLibrary = $0 })) }
        .onAppear {
            guard !initialized else { return }; initialized = true
            workflowID = coordinator.settings.settings.workflowLibrary.defaultID
            definition = coordinator.settings.settings.workflowDefinition
            projectID = coordinator.registry.projects.first?.id; selectProject()
        }
        .onChange(of: workflowID) {
            if let saved = coordinator.settings.settings.workflowLibrary.workflow(workflowID) { definition = saved.definition; error = "" }
        }
        .onChange(of: projectID) { selectProject() }
    }
    private func selectProject() {
        guard let project else { return }
        if let saved = project.verificationCommand { command = saved }
        else if FileManager.default.fileExists(atPath: project.url.appendingPathComponent("Package.swift").path) { command = "swift test" }
        else { command = "" }
    }
}
