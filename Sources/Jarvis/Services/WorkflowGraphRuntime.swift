import Foundation

extension Coordinator {
    func startGraphWorkflow(project: Project, task: String, command: String, definition: WorkflowDefinition) -> Bool {
        if let error = definition.validationError { showError(error); return false }
        if definition.usesVerification && command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { showError("Scrivi il comando per il nodo Verifica."); return false }
        var configurations: [String: AgentExecutionConfiguration] = [:]
        for node in definition.nodes where node.kind != .approval {
            let agent = node.agent
            guard [.verification, .command].contains(node.kind) || executable(for: agent) != nil else { showError("Configura la CLI di \(agent.displayName) per \(node.title)."); return false }
            var config = workflowConfiguration(project: project, agent: agent, readOnly: [.plan, .review, .evaluation].contains(node.kind))
            let model = node.model.trimmingCharacters(in: .whitespacesAndNewlines)
            if !model.isEmpty { config.model = model; if config.codex != nil { config.codex?.model = model } }
            if node.kind.usesModel, let error = config.codex?.configurationError { showError(error); return false }
            configurations[node.id] = config
        }
        let worker = definition.nodes.first { $0.kind == .implementation } ?? definition.nodes.first { $0.kind.usesModel } ?? definition.node(definition.entry)!
        var session = Session(id: sessions.nextID(), projectName: project.name, projectPath: project.path, agent: worker.agent,
            task: task, executionConfiguration: configurations[worker.id], turns: [],
            workflow: AgentWorkflow(originalTask: task, verificationCommand: command,
                maxCorrections: definition.nodes.first { $0.kind == .correction }?.maxVisits, correctionsScheduled: 0,
                definition: definition, nodeConfigurations: configurations, nodeVisits: [:], stepsExecuted: 0))
        enqueueGraphNode(&session, id: definition.entry)
        guard session.canResumeQueue else { showError(session.workflow?.detail ?? "Percorso non valido."); return false }
        do { try sessions.save(session, kind: .accepted, turnID: session.queuedTurns.first?.id) }
        catch { showError(error.localizedDescription); return false }
        return resumePending(sessionID: session.id)
    }

    /// Called only after the process exits. The caller flushes this entire snapshot before dispatch.
    func advanceGraphWorkflow(_ session: inout Session, turnID: UUID, code: Int32) {
        guard let graph = session.workflow?.definition, let turn = session.turns?.first(where: { $0.id == turnID }),
              turn.workflowNodeID == session.workflow?.currentNodeID, let node = graph.node(turn.workflowNodeID) else { return }
        guard code == 0, session.status == .done, turn.state == .completed else {
            let actualFailure = [.verification, .command].contains(node.kind) && (1...125).contains(code) &&
                turn.backendOutcome == .failed && turn.state == .failed && session.status == .failed
            if actualFailure {
                session.workflow?.failureTurnID = turnID
                followGraphEdge(&session, from: node, success: false)
            } else { blockGraph(&session, "\(node.title) fermata: controlla risultato e log.", state: turn.state) }
            return
        }
        switch node.kind {
        case .plan:
            guard let report = AgentWorkflow.planReport(turn.resultText ?? "", token: turnID) else {
                blockGraph(&session, "Rapporto del Piano mancante o non valido. Implementazione non avviata."); return
            }
            session.workflow?.plan = report
            guard report.verdict == "ready" else { blockGraph(&session, report.summary); return }
            session.workflow?.planApproved = graph.requiresPlanApproval ? false : true
        case .implementation, .correction:
            session.workflow?.reviewPassed = nil; session.workflow?.verificationPassed = nil
        case .action, .research, .analysis, .testing, .documentation, .summary:
            session.workflow?.reviewPassed = nil; session.workflow?.verificationPassed = nil
            guard let report = AgentWorkflow.actionReport(turn.resultText ?? "", token: turnID) else {
                blockGraph(&session, "Rapporto di \(node.title) mancante o non valido."); return
            }
            session.workflow?.detail = report.summary
            if report.verdict != "passed" {
                guard report.verdict == "failed" else { blockGraph(&session, report.summary); return }
                if let index = session.turns?.firstIndex(where: { $0.id == turnID }) { session.turns?[index].state = .failed }
                session.workflow?.failureTurnID = turnID
                followGraphEdge(&session, from: node, success: false); return
            }
        case .evaluation:
            guard let report = AgentWorkflow.scoreReport(turn.resultText ?? "", token: turnID), report.verdict == "scored", let score = report.score else {
                blockGraph(&session, "Valutazione di \(node.title) bloccata: rapporto score mancante, non valido o privo di evidenze."); return
            }
            let results = (session.workflow?.scoreResults ?? []) + [WorkflowScoreResult(nodeID: node.id, turnID: turnID, score: score, target: node.resolvedTargetScore, summary: report.summary)]
            session.workflow?.scoreResults = results
            session.workflow?.detail = "Score \(score.formatted()) / 100 · obiettivo \(node.resolvedTargetScore.formatted()). " + report.summary
            if score < node.resolvedTargetScore {
                if let index = session.turns?.firstIndex(where: { $0.id == turnID }) { session.turns?[index].state = .failed }
                session.workflow?.failureTurnID = turnID
                followGraphEdge(&session, from: node, success: false); return
            }
        case .review:
            guard let report = AgentWorkflow.reviewReport(turn.resultText ?? "", token: turnID) else {
                blockGraph(&session, "Rapporto di review mancante o non valido. Verifica non eseguita."); return
            }
            session.workflow?.reviewPassed = report.verdict == "passed"
            session.workflow?.detail = ([report.summary] + report.findings).joined(separator: "\n")
            if report.verdict != "passed" {
                if let index = session.turns?.firstIndex(where: { $0.id == turnID }) { session.turns?[index].state = report.verdict == "blocked" ? .blocked : .failed }
                guard report.verdict == "failed", report.findings.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                    blockGraph(&session, report.summary); return
                }
                session.workflow?.failureTurnID = turnID
                followGraphEdge(&session, from: node, success: false); return
            }
        case .verification: session.workflow?.verificationPassed = true
        case .command:
            // A shell action can alter files: require a new independent review and check afterwards.
            session.workflow?.reviewPassed = nil; session.workflow?.verificationPassed = nil
        case .approval: return
        }
        followGraphEdge(&session, from: node, success: true)
    }

    private func followGraphEdge(_ session: inout Session, from node: WorkflowNode, success: Bool) {
        if success, node.kind.supportsRepetitions, (session.workflow?.repetition ?? 1) < (node.repetitions ?? 1) {
            enqueueGraphNode(&session, id: node.id, repeating: true); return
        }
        let next = success ? node.success : node.failure
        if let next { enqueueGraphNode(&session, id: next); return }
        let development = session.workflow?.definition?.isDevelopment != false
        if success, !development || (session.workflow?.reviewPassed == true && session.workflow?.verificationPassed == true) {
            session.workflow?.state = .completed
            session.workflow?.detail = development ? "Workflow completato: review e verifica superate." : "Workflow completato: percorso configurato concluso."
            session.status = .done; session.task = session.workflow?.originalTask ?? session.task
        } else {
            blockGraph(&session, success ? "Percorso concluso senza review e verifica valide. Collega questi nodi prima dell'uscita." : "\(node.title) non superata. Nessuna azione configurata sul fallimento.", state: .failed)
        }
    }

    private func enqueueGraphNode(_ session: inout Session, id: String, repeating: Bool = false) {
        guard var workflow = session.workflow, let graph = workflow.definition, let node = graph.node(id) else {
            blockGraph(&session, "Nodo del workflow non trovato."); return
        }
        let visits = workflow.nodeVisits?[id] ?? 0
        guard visits < node.maxVisits, (workflow.stepsExecuted ?? 0) < 64 else {
            blockGraph(&session, "Limite raggiunto per \(node.title) (\(node.maxVisits) esecuzioni). Workflow fermato.", state: .failed); return
        }
        if node.kind == .plan {
            workflow.plan = nil; workflow.planApproved = false
            workflow.reviewPassed = nil; workflow.verificationPassed = nil
        }
        if graph.isDevelopment, [.implementation, .correction].contains(node.kind) || node.kind.usesActionReport, workflow.planApproved != true {
            blockGraph(&session, "Approva il Piano prima dell'implementazione."); return
        }
        if graph.hasPlan, graph.requiresPlanApproval, workflow.plan != nil, workflow.planApproved != true, node.kind != .plan, node.kind != .approval {
            blockGraph(&session, "Approva il Piano prima di continuare il percorso."); return
        }
        if graph.isDevelopment, node.kind == .review, session.turns?.last(where: { $0.workflowStage == .implementation })?.state != .completed {
            blockGraph(&session, "La review richiede un'implementazione completata."); return
        }
        if graph.isDevelopment, node.kind == .verification, workflow.reviewPassed != true {
            blockGraph(&session, "La verifica richiede una review superata."); return
        }
        workflow.nodeVisits = workflow.nodeVisits ?? [:]; workflow.nodeVisits?[id] = visits + 1
        workflow.stepsExecuted = (workflow.stepsExecuted ?? 0) + 1
        workflow.repetition = repeating ? (workflow.repetition ?? 1) + 1 : 1
        workflow.currentNodeID = id; workflow.state = .dispatched; workflow.detail = "\(node.title) in attesa di avvio"
        workflow.awaitingPlanApproval = false
        session.workflow = workflow
        if node.kind == .approval {
            guard workflow.plan?.verdict == "ready" else { blockGraph(&session, "Genera un Piano valido prima dell'approvazione."); return }
            if graph.requiresPlanApproval, workflow.planApproved != true {
                session.workflow?.awaitingPlanApproval = true; session.workflow?.state = .blocked
                session.workflow?.detail = "Piano pronto. Leggilo e scegli se approvarlo."
                session.status = .needsInput; session.finishedAt = nil; session.task = workflow.originalTask; return
            }
            session.workflow?.planApproved = true
            followGraphEdge(&session, from: node, success: true); return
        }
        guard let config = workflow.nodeConfigurations?[id], let stage = node.kind.stage else { blockGraph(&session, "Configurazione del nodo mancante."); return }
        var turn = SessionTurn(task: "", configuration: config, workflowStage: stage)
        turn.workflowNodeID = id
        turn.workflowAttempt = workflow.attempt
        let plannedTask = workflow.originalTask + (workflow.plan.map { "\n\nImplementation plan:\n" + $0.text } ?? "")
        switch node.kind {
        case .plan:
            turn.task = AgentWorkflow.planningTask(task: workflow.originalTask, command: workflow.verificationCommand, token: turn.id)
            turn.guidance = "Read-only planning only. The structured plan report takes precedence over conversational instructions."
        case .implementation:
            turn.task = plannedTask; turn.guidance = memory.agentGuidance
            session.workflow?.reviewPassed = nil; session.workflow?.verificationPassed = nil
        case .correction:
            guard let failure = session.turns?.first(where: { $0.id == workflow.failureTurnID }) else { blockGraph(&session, "La correzione richiede un fallimento precedente."); return }
            session.workflow?.correctionsScheduled = workflow.attempt + 1
            turn.workflowAttempt = workflow.attempt + 1; turn.repairSourceTurnID = failure.id
            turn.task = AgentWorkflow.correctionTask(task: plannedTask, evidence: AgentWorkflow.failureEvidence(failure), command: workflow.verificationCommand, attempt: workflow.attempt + 1, limit: workflow.correctionLimit, development: graph.isDevelopment)
            turn.guidance = memory.agentGuidance
            session.workflow?.reviewPassed = nil; session.workflow?.verificationPassed = nil
        case .review:
            session.workflow?.reviewPassed = nil; session.workflow?.verificationPassed = nil
            let implementation = session.turns?.last(where: { $0.workflowStage == .implementation || $0.workflowStage == .action })?.resultText ?? ""
            let failure = session.turns?.first(where: { $0.id == workflow.failureTurnID })
            turn.task = AgentWorkflow.reviewTask(task: plannedTask, implementation: implementation, token: turn.id, previousFailure: failure.map(AgentWorkflow.failureEvidence) ?? "")
            turn.guidance = "Independent read-only review. The structured review report takes precedence over conversational instructions."
        case .evaluation:
            turn.task = AgentWorkflow.scoreTask(criterion: node.resolvedInstructions, task: workflow.originalTask, previousResult: session.turns?.last?.resultText ?? "", target: node.resolvedTargetScore, token: turn.id)
            turn.guidance = "Independent read-only evaluation. The structured score report takes precedence over conversational final-answer instructions. Never edit files or run commands with side effects."
        case .verification: turn.task = workflow.verificationCommand
        case .command:
            turn.task = node.command
            session.workflow?.reviewPassed = nil; session.workflow?.verificationPassed = nil
        case .action, .research, .analysis, .testing, .documentation, .summary:
            let previous = session.turns?.last?.resultText ?? ""
            turn.task = AgentWorkflow.actionTask(instructions: node.resolvedInstructions, task: workflow.originalTask,
                plan: workflow.plan?.text ?? "", previousResult: previous, token: turn.id, development: graph.isDevelopment,
                repetition: workflow.repetition ?? 1, repetitions: node.repetitions ?? 1)
            turn.guidance = (memory.agentGuidance ?? "") + "\nThe structured action report takes precedence over conversational final-answer instructions."
            session.workflow?.reviewPassed = nil; session.workflow?.verificationPassed = nil
        case .approval: return
        }
        session.turns = (session.turns ?? []) + [turn]
        session.status = .done; session.activity = ""; session.task = workflow.originalTask
    }

    private func blockGraph(_ session: inout Session, _ detail: String, state: TurnState = .blocked) {
        if let index = session.turns?.lastIndex(where: { $0.workflowNodeID == session.workflow?.currentNodeID && $0.state == .completed }), state == .blocked {
            session.turns?[index].state = .blocked
        }
        session.workflow?.state = state; session.workflow?.detail = detail; session.workflow?.awaitingPlanApproval = false
        session.status = state == .cancelled ? .cancelled : state == .blocked ? .needsInput : .failed
        session.task = session.workflow?.originalTask ?? session.task
        for index in session.turns?.indices ?? [].indices where session.turns?[index].state == .queued {
            session.turns?[index].state = .cancelled; session.turns?[index].finishedAt = Date()
        }
    }

    @discardableResult
    func decidePlan(sessionID: String, approve: Bool) -> Bool {
        guard var session = sessions.session(sessionID), !session.usesRetiredAgent, session.status == .needsInput, session.workflow?.state == .blocked, session.currentTurnID == nil,
              session.workflow?.awaitingPlanApproval == true, let graph = session.workflow?.definition,
              let node = graph.node(session.workflow?.currentNodeID), node.kind == .approval else { return false }
        session.workflow?.awaitingPlanApproval = false; session.workflow?.planApproved = approve
        if approve { followGraphEdge(&session, from: node, success: true) }
        else { blockGraph(&session, "Piano rifiutato. Nessuna implementazione avviata.", state: .cancelled) }
        do { try sessions.save(session, kind: approve ? .planApproved : .planRejected) }
        catch { showError(error.localizedDescription); return false }
        if approve { return session.canResumeQueue ? resumePending(sessionID: sessionID) : session.workflow?.state == .completed }
        return true
    }
}
