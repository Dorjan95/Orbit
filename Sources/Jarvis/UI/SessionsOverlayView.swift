import SwiftUI

/// Draggable session stack using EnvHalo’s black surfaces and lime status accents.
struct SessionsOverlayView: View {
    let store: SessionStore
    let chord: Hotkey
    var maximumHeight: CGFloat = 560
    let onClose: () -> Void
    let onOpen: (Session) -> Void
    let onLog: (Session) -> Void
    let onReply: (Session, String) -> Void
    let onStop: (Session) -> Void
    let onDismiss: (Session) -> Void
    /// "Pulisci": clears the finished sessions and the conversation with them.
    let onClear: () -> Void
    var onResumePending: (Session) -> Void = { _ in }
    var onApproval: (Session, UUID, String) -> Void = { _, _, _ in }
    var onPlanDecision: (Session, Bool) -> Void = { _, _ in }
    var onSteer: (Session, String) -> Bool = { _, _ in false }
    var onDragState: (Bool) -> Void = { _ in }
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            ScrollView(showsIndicators: false) {
                SessionGroupsView(store: store, chord: chord, onOpen: onOpen, onLog: onLog,
                                  onReply: onReply, onStop: onStop, onDismiss: onDismiss, onResumePending: onResumePending, onApproval: onApproval, onPlanDecision: onPlanDecision, onSteer: onSteer)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .frame(height: min(max(contentHeight, 100), maximumHeight - 56))
        }
        .padding(12)
        .frame(width: 380)
        .frame(minHeight: 96)
        .haloSurface(radius: 14)
        .animation(Motion.spring, value: store.visible.map(\.id))
    }

    private var finishedCount: Int { store.finishedVisible.count }

    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal").foregroundStyle(OrbitDesign.secondaryText)
                Text("SESSIONI").font(.system(size: 11, weight: .heavy, design: .rounded)).tracking(1)
            }
            .frame(height: 28)
            .overlay(WindowDragSurface(onDragState: onDragState))
            .help("Trascina per spostare il pannello")
            if !store.running.isEmpty {
                Text("\(store.running.count) in corso")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(OrbitDesign.lime.opacity(0.15), in: Capsule())
                    .foregroundStyle(OrbitDesign.lime)
                    .contentTransition(.numericText())
            }
            Spacer()
            if finishedCount > 0 {
                Button { onClear() } label: {
                    Text("Pulisci").font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                }
                .buttonStyle(PressableStyle())
                .foregroundStyle(.secondary)
                .help("Nascondi le sessioni finite")
            }
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Color.primary.opacity(0.06), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(PressableStyle())
            .help("Chiudi il pannello")
        }
        .padding(.horizontal, 4)
    }

}

/// Shared by the floating panel and the full session page in Settings.
struct SessionGroupsView: View {
    let store: SessionStore
    let chord: Hotkey
    let onOpen: (Session) -> Void
    let onLog: (Session) -> Void
    let onReply: (Session, String) -> Void
    let onStop: (Session) -> Void
    let onDismiss: (Session) -> Void
    var onResumePending: (Session) -> Void = { _ in }
    var onApproval: (Session, UUID, String) -> Void = { _, _, _ in }
    var onPlanDecision: (Session, Bool) -> Void = { _, _ in }
    var onSteer: (Session, String) -> Bool = { _, _ in false }
    @State private var now = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = store.persistenceError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(.orange)
            }
            sectionHeading("SESSIONI ATTIVE", count: store.activeVisible.count, symbol: "bolt.fill")
            if store.activeVisible.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Nessuna sessione attiva").font(.system(size: 13, weight: .semibold))
                    Text("Di’ «Hey Orbit» e chiedi di lavorare su un progetto.")
                        .font(.system(size: 12)).foregroundStyle(OrbitDesign.secondaryText)
                    HStack(spacing: 5) {
                        Text("Oppure tieni premuto").font(.system(size: 11)).foregroundStyle(OrbitDesign.secondaryText)
                        KeyCaps(hotkey: chord)
                    }
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(OrbitDesign.surface, in: RoundedRectangle(cornerRadius: 12))
            } else {
                ForEach(store.activeVisible) { card($0) }
            }
            if !store.finishedVisible.isEmpty {
                sectionHeading("CONCLUSE", count: store.finishedVisible.count, symbol: "clock")
                    .padding(.top, 8)
                ForEach(store.finishedVisible) { card($0) }
            }
        }
        .animation(Motion.spring, value: store.visible.map { $0.id + $0.status.rawValue })
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                if !store.activeVisible.isEmpty || store.visible.contains(where: { ($0.finishedAt.map { now.timeIntervalSince($0) } ?? 0) < 660 }) {
                    now = Date()
                }
            }
        }
    }

    private func sectionHeading(_ title: String, count: Int, symbol: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).foregroundStyle(OrbitDesign.lime)
            Text(title).font(.system(size: 10, weight: .bold)).tracking(0.7)
            Spacer()
            Text("\(count)").font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(OrbitDesign.secondaryText)
        }.padding(.horizontal, 4).padding(.vertical, 3)
    }

    private func card(_ s: Session) -> some View {
        SessionCard(session: s, now: now, onOpen: { onOpen(s) }, onLog: { onLog(s) },
                    onReply: { onReply(s, $0) }, onStop: { onStop(s) }, onDismiss: { onDismiss(s) },
                    onResumePending: { onResumePending(s) }, onApproval: { onApproval(s, $0, $1) }, onPlanDecision: { onPlanDecision(s, $0) }, onSteer: { onSteer(s, $0) })
            .transition(Motion.reduce ? .opacity : .orbitPixels)
    }
}

struct SessionCard: View {
    let session: Session
    let now: Date
    let onOpen: () -> Void
    let onLog: () -> Void
    let onReply: (String) -> Void
    let onStop: () -> Void
    let onDismiss: () -> Void
    var onResumePending: () -> Void = {}
    var onApproval: (UUID, String) -> Void = { _, _ in }
    var onPlanDecision: (Bool) -> Void = { _ in }
    var onSteer: (String) -> Bool = { _ in false }
    @State private var steeringInput = false
    @State private var hover = false
    @State private var replying = false
    @State private var reply = ""
    @FocusState private var replyFocused: Bool

    private var collapsed: Bool {
        guard session.status != .needsInput, let f = session.finishedAt else { return false }
        return now.timeIntervalSince(f) > 600
    }

    /// Last meaningful line of what the agent said: the answer to "so what did it do?".
    private var outcome: String? {
        guard session.workflow == nil, !session.status.isActive else { return nil }
        let line = session.resultText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty && !$0.hasPrefix("```") }
        return line.map { $0.replacingOccurrences(of: "**", with: "") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Rectangle().fill(session.status.tint).frame(width: 6, height: 6)
                Text(session.projectName).font(.system(size: 14, weight: .bold, design: .rounded)).lineLimit(1)
                AgentIcon(agent: session.agent, size: 12).help(session.agent.displayName)
                Spacer(minLength: 4)
                Text(timeLabel).font(.system(size: 10, design: .monospaced)).foregroundStyle(OrbitDesign.tertiaryText).monospacedDigit()
                StatusBadge(status: session.status)
            }
            if let backend = session.codexBackend, backend.provider.isLocal {
                Text("LOCALE · " + backend.model).font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(OrbitDesign.secondaryText).lineLimit(1)
            }
            Text(session.workflow?.originalTask ?? session.task).font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(2).lineSpacing(1)
            if session.usesRetiredAgent {
                Text("Agente esterno rimosso · sessione conservata nello storico")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if session.workflow != nil { WorkflowProgressView(session: session, onPlanDecision: onPlanDecision) }
            if !session.queuedTurns.isEmpty {
                HStack {
                    Text(session.workflow == nil ? "\(session.queuedTurns.count) \(session.queuedTurns.count == 1 ? "seguito in coda" : "seguiti in coda")" : "\(session.queuedTurns.count) \(session.queuedTurns.count == 1 ? "fase in attesa" : "fasi in attesa")")
                        .font(.system(size: 11)).foregroundStyle(OrbitDesign.secondaryText)
                    Spacer()
                    if session.canResumeQueue { action("play.fill", "Riprendi coda", onResumePending) }
                }
            }
            if session.turns?.last(where: { $0.state != .queued })?.state == .interrupted {
                Text("Turno interrotto: verifica il lavoro prima di continuare.")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }
            if !collapsed || replying {
                if session.status == .running && !session.activity.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(OrbitDesign.lime)
                        Text(session.activity).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .transition(.opacity)
                }
                if let outcome, session.status != .needsInput {
                    Text(outcome)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.primary.opacity(0.85))
                        .lineLimit(2)
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(session.status.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                ForEach(session.pendingApprovals) { approval in
                    ApprovalRequestView(approval: approval) { onApproval(approval.id, $0) }
                }
                if session.status == .needsInput && session.pendingApprovals.isEmpty {
                    Label(session.workflow == nil ? "Serve un tuo input: aprila e continua da lì" : "Workflow bloccato: controlla i risultati e le informazioni richieste.", systemImage: "hand.raised.fill")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.orange)
                }
                if replying && steeringInput {
                    Text("Interrompe il turno attuale e riprende lo stesso contesto. Le modifiche già fatte restano nel progetto.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if replying {
                    HStack(spacing: 6) {
                        TextField(steeringInput ? "Nuova direzione per il lavoro in corso" : "Cosa deve fare adesso?", text: $reply)
                            .textFieldStyle(.plain).font(.system(size: 12))
                            .focused($replyFocused)
                            .onSubmit(sendReply)
                            .onExitCommand { replying = false }
                        Button(action: sendReply) {
                            Image(systemName: "arrow.up.circle.fill").font(.system(size: 16))
                                .foregroundStyle(reply.isEmpty ? Color.secondary : OrbitDesign.lime)
                        }
                        .buttonStyle(PressableStyle()).disabled(reply.isEmpty)
                    }
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .onAppear { replyFocused = true }
                }
            }
            if session.offersSteering {
                action("arrow.triangle.turn.up.right.diamond", "Reindirizza") { steeringInput = true; replying = true }
            }
            if session.steering != nil && session.currentTurnID != nil {
                Text("Attende la conferma dell'interruzione…").font(.system(size: 11)).foregroundStyle(.orange)
            }
            Group {
                HStack(spacing: 6) {
                    action("terminal", "Terminale", onOpen)
                    action("doc.text", "Log", onLog)
                    if !session.usesRetiredAgent && session.workflow == nil && (session.status == .running || session.agentSessionID != nil || session.turns != nil) {
                        action("arrowshape.turn.up.left", "Rispondi") { steeringInput = false; replying.toggle() }
                    }
                    Spacer()
                    if session.hasPendingWork { action("stop.fill", "Ferma", onStop, tint: .red) }
                    else { action("xmark", "Chiudi", onDismiss) }
                }
                .transition(.opacity)
            }
        }
        .padding(12)
        .background(hover ? OrbitDesign.raisedSurface : OrbitDesign.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(alignment: .bottom) { if session.status == .running { ProgressShimmer().padding(.horizontal, 14) } }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover { hover = $0 }
        .animation(Motion.spring, value: hover)
        .animation(Motion.spring, value: replying)
        .animation(Motion.spring, value: session.status)
    }

    private func sendReply() {
        let t = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if steeringInput && !onSteer(t) { return }
        if !steeringInput { onReply(t) }
        reply = ""; replying = false
    }

    private func action(_ symbol: String, _ label: String, _ act: @escaping () -> Void, tint: Color = .secondary) -> some View {
        Button(action: act) {
            Label(label, systemImage: symbol)
                .font(.system(size: 11, weight: .medium))
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .frame(minHeight: 28)
                .background(Color.primary.opacity(0.06), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .foregroundStyle(tint)
    }

    private var timeLabel: String {
        if session.status == .running { return SessionStore.format(now.timeIntervalSince(session.startedAt)) }
        guard let f = session.finishedAt else { return "" }
        let ago = now.timeIntervalSince(f)
        return ago < 60 ? "adesso" : "\(SessionStore.format(ago)) fa"
    }
}

/// 1-pt shimmer along the bottom edge of a running card.
struct ProgressShimmer: View {
    @State private var on = false
    var body: some View {
        GeometryReader { g in
            Capsule().fill(LinearGradient(colors: [.clear, OrbitDesign.lime.opacity(0.7), .clear], startPoint: .leading, endPoint: .trailing))
                .frame(width: g.size.width * 0.4, height: 1)
                .offset(x: (on ? 1 : -0.4) * g.size.width)
                .animation(Motion.reduce ? nil : .linear(duration: 1.6).repeatForever(autoreverses: false), value: on)
                .onAppear { on = true }
        }
        .frame(height: 1)
    }
}
