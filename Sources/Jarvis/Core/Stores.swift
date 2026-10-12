import Foundation
import Observation

@MainActor @Observable
final class SettingsStore {
    var settings: Settings { didSet { JSONStore.save(settings, to: AppPaths.settings) } }
    init() { settings = JSONStore.load(Settings.self, from: AppPaths.settings) ?? Settings() }
}

@MainActor @Observable
final class ProjectRegistry {
    var projects: [Project] { didSet { JSONStore.save(projects, to: AppPaths.projects) } }
    init() { projects = JSONStore.load([Project].self, from: AppPaths.projects) ?? [] }

    func add(_ p: Project) { projects.append(p) }
    func remove(_ id: Project.ID) { projects.removeAll { $0.id == id } }
    func update(_ p: Project) { if let i = projects.firstIndex(where: { $0.id == p.id }) { projects[i] = p } }

    /// Exact name, then alias, then case-insensitive substring.
    func resolve(_ name: String?) -> Project? {
        guard let name = name?.trimmingCharacters(in: .whitespaces).lowercased(), !name.isEmpty else { return nil }
        if let p = projects.first(where: { $0.name.lowercased() == name }) { return p }
        if let p = projects.first(where: { $0.aliases.contains { $0.lowercased() == name } }) { return p }
        // Fuzzy: whole-word containment either way, preferring the longest (most specific) project name.
        func words(_ x: String) -> Set<String> { Set(x.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }) }
        let q = words(name)
        let candidates = projects.filter { p in
            let pw = words(p.name.lowercased()) ; guard !pw.isEmpty else { return false }
            return pw.isSubset(of: q) || q.isSubset(of: pw) || p.aliases.contains { words($0.lowercased()).isSubset(of: q) }
        }
        return candidates.max { words($0.name).count < words($1.name).count }
    }

    /// Summary block for the orchestrator prompt (§4.1).
    var promptSummary: String {
        projects.isEmpty ? "- (none registered yet)" :
        projects.map { "- \($0.name) · \($0.path) · [\($0.aliases.joined(separator: ", "))] · \($0.defaultAgent.rawValue) · workflow verification: \($0.verificationCommand?.isEmpty == false ? "configured" : "missing")" }.joined(separator: "\n")
    }

    static func suggestedName(for url: URL) -> String {
        url.lastPathComponent.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
    }
}

@MainActor @Observable
final class SessionStore {
    private(set) var sessions: [Session] = []
    private var counter: Int
    private let snapshotURL: URL
    private let journal: SessionJournal
    private(set) var persistenceError: String?

    init(root: URL = AppPaths.root) {
        snapshotURL = root.appendingPathComponent("sessions.json")
        journal = SessionJournal(url: root.appendingPathComponent("session-events.jsonl"))
        let snapshot = JSONStore.load([Session].self, from: snapshotURL)
        let loaded = snapshot ?? []
        counter = loaded.compactMap { Int($0.id.dropFirst(2)) }.max() ?? 0
        sessions = loaded
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let events = try journal.replay()
            if events.isEmpty {
                if snapshot == nil && FileManager.default.fileExists(atPath: snapshotURL.path) {
                    throw SessionJournalError.unavailable("sessions.json non valido; nessuna sessione è stata sovrascritta.")
                }
                try journal.bootstrap(loaded)
            } else {
                var latest: [String: Session] = [:]
                for event in events { latest[event.session.id] = event.session }
                sessions = latest.values.sorted { $0.startedAt > $1.startedAt }
                counter = latest.keys.compactMap { Int($0.dropFirst(2)) }.max() ?? counter
            }
        } catch {
            persistenceError = error.localizedDescription
            AppLog.write("session journal: \(error)")
        }
        // Removed providers remain historical identities, never remote Codex/Claude contexts.
        for original in sessions where original.usesRetiredAgent &&
            (original.hasPendingWork || original.pid != nil || !original.pendingApprovals.isEmpty ||
             (original.turns ?? []).contains(where: { $0.state == .dispatched })) {
            var archived = original
            if original.status.isOngoing || original.currentTurnID != nil { archived.status = .failed }
            archived.currentTurnID = nil; archived.pid = nil; archived.steering = nil; archived.finishedAt = Date()
            archived.activity = "Agente esterno rimosso: sessione conservata nello storico."
            archived.workflow?.state = .cancelled
            archived.workflow?.detail += "\nAgente esterno rimosso: nessuna fase verrà rilanciata."
            archived.approvals = archived.approvals?.map {
                var approval = $0
                if approval.state == .pending { approval.state = .expired; approval.decidedAt = Date() }
                return approval
            }
            archived.turns = archived.turns?.map {
                var turn = $0
                if turn.state == .queued || turn.state == .dispatched {
                    turn.state = turn.state == .queued ? .cancelled : .interrupted; turn.finishedAt = Date()
                }
                return turn
            }
            do { try save(archived, kind: .recovered) }
            catch { if let index = sessions.firstIndex(where: { $0.id == archived.id }) { sessions[index] = archived } }
        }
        // PIDs saved across a restart are not reliable process identities. Do not
        // signal them or repeat uncertain work; retain only requests still queued.
        for original in sessions where original.status == .running || original.currentTurnID != nil || (original.status == .needsInput && original.pid != nil) || (original.turns ?? []).contains(where: { $0.state == .dispatched }) || !original.pendingApprovals.isEmpty {
            var recovered = original
            recovered.status = .failed; recovered.finishedAt = Date(); recovered.pid = nil
            recovered.activity = "Interrotta dal riavvio: verifica il lavoro prima di continuare"
            recovered.currentTurnID = nil
            recovered.workflow?.state = .interrupted
            recovered.workflow?.detail = "Workflow interrotto dal riavvio: nessuna fase viene rilanciata automaticamente."
            recovered.approvals = recovered.approvals?.map {
                var approval = $0
                if approval.state == .pending { approval.state = .expired; approval.decidedAt = Date() }
                return approval
            }
            if var turns = recovered.turns {
                for index in turns.indices where turns[index].state == .dispatched {
                    turns[index].state = .interrupted; turns[index].finishedAt = Date()
                }
                recovered.turns = turns
            }
            do { try save(recovered, kind: .recovered) }
            catch {
                if let index = sessions.firstIndex(where: { $0.id == recovered.id }) { sessions[index] = recovered }
            }
        }
        if persistenceError == nil { trimAndSave() }
    }

    var running: [Session] { sessions.filter { $0.status == .running } }
    var activeVisible: [Session] { visible.filter(\.hasPendingWork) }
    var finishedVisible: [Session] { visible.filter { !$0.hasPendingWork } }
    var visible: [Session] {
        sessions.filter { !$0.dismissed }.sorted {
            if $0.hasPendingWork != $1.hasPendingWork { return $0.hasPendingWork }
            return $0.startedAt > $1.startedAt
        }
    }

    func nextID() -> String { counter += 1; return String(format: "s_%02d", counter) }

    /// A successful return means the lifecycle record is flushed to disk.
    func save(_ session: Session, kind: SessionEventKind, turnID: UUID? = nil) throws {
        guard persistenceError == nil else { throw SessionJournalError.unavailable(persistenceError!) }
        do { try journal.append(session, kind: kind, turnID: turnID) }
        catch {
            persistenceError = error.localizedDescription
            throw error
        }
        if let index = sessions.firstIndex(where: { $0.id == session.id }) { sessions[index] = session }
        else { sessions.insert(session, at: 0) }
        trimAndSave()
    }

    func insert(_ s: Session) {
        do { try save(s, kind: .accepted) } catch { AppLog.write("session insert: \(error)") }
    }
    func update(_ id: String, event: SessionEventKind? = nil, _ mutate: (inout Session) -> Void) {
        guard var session = session(id) else { return }
        mutate(&session)
        if let event {
            do { try save(session, kind: event, turnID: session.currentTurnID) }
            catch { AppLog.write("session update: \(error)") }
        } else if let index = sessions.firstIndex(where: { $0.id == id }) {
            sessions[index] = session; trimAndSave()
        }
    }
    func session(_ id: String) -> Session? { sessions.first { $0.id == id } }
    func dismiss(_ id: String) { update(id, event: .updated) { $0.dismissed = true } }
    func clearFinished() { for s in sessions where !s.hasPendingWork { dismiss(s.id) } }

    private func trimAndSave() {
        // Never evict active sessions or accepted work because history is full.
        let protected = sessions.filter(\.hasPendingWork)
        let history = sessions.filter { !$0.hasPendingWork }
        sessions = protected + history.prefix(max(0, 100 - protected.count))
        if persistenceError == nil { JSONStore.save(sessions, to: snapshotURL) }
    }

    /// Summary block for the orchestrator prompt (§4.1).
    var promptSummary: String {
        // Sessions closed from the panel are gone for Jarvis too: it no longer answers from them or continues them.
        let recent = sessions.filter { !$0.dismissed }.prefix(8)
        return recent.isEmpty ? "- (none)" :
        recent.map { s in
            var line = "- \(s.id) · \(s.projectName) · \(s.agent.rawValue) · \(s.status.rawValue) · \"\(s.task.prefix(60))\" · \(Self.format(s.elapsed))"
            if s.offersSteering { line += " · steering available (interactive implementation)" }
            if s.usesRetiredAgent { line += " · historical only: removed provider, no follow-up or resume" }
            if let workflow = s.workflow { line += " · workflow: \(workflow.state.rawValue) · \(workflow.detail.prefix(200))" }
            if !s.queuedTurns.isEmpty { line += " · queued: \(s.queuedTurns.count)" }
            if s.status == .running, !s.activity.isEmpty { line += " · now: \(s.activity.prefix(60))" }
            if let end = s.finishedAt {
                line += " · finished \(Int(Date().timeIntervalSince(end) / 60)) min ago"
                // The result itself, so a question it already answered gets answered now, without reopening the session.
                let r = s.resultText.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
                // Fresh results whole (a mail summary cut at 700 chars lost the third mail, 29/09), older ones short.
                let fresh = Date().timeIntervalSince(end) < 30 * 60
                if !r.isEmpty { line += " · result: \"\(r.prefix(fresh ? 2500 : 300))\"" }
            }
            return line
        }.joined(separator: "\n")
    }

    /// Elapsed time the way it is said out loud: "40 secondi", "3 minuti", "un'ora e 5 minuti".
    static func spoken(_ t: TimeInterval) -> String {
        let s = Int(t)
        if s < 60 { return "\(s) secondi" }
        let m = s / 60
        if s < 3600 { return m == 1 ? "un minuto" : "\(m) minuti" }
        let h = s / 3600, rm = (s % 3600) / 60
        let hs = h == 1 ? "un'ora" : "\(h) ore"
        return rm == 0 ? hs : "\(hs) e \(rm) minuti"
    }

    static func format(_ t: TimeInterval) -> String {
        let s = Int(t)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m\(String(format: "%02d", s % 60))s" }
        return "\(s / 3600)h\(String(format: "%02d", (s % 3600) / 60))m"
    }
}

/// Long-term memory (§ memory): facts the user asked Jarvis to keep, plus a short rolling conversation history.
/// Facts are injected into every orchestrator turn and into every coding-agent session; turns only into the orchestrator.
@MainActor @Observable
final class MemoryStore {
    private(set) var memories: [Memory] { didSet { JSONStore.save(memories, to: AppPaths.memory) } }
    private(set) var turns: [ConversationTurn] { didSet { JSONStore.save(turns, to: AppPaths.conversation) } }
    static let maxMemories = 200
    static let maxTurns = 12

    init() {
        memories = JSONStore.load([Memory].self, from: AppPaths.memory) ?? []
        turns = JSONStore.load([ConversationTurn].self, from: AppPaths.conversation) ?? []
    }

    /// Adds a fact; near-duplicates (case-insensitive) are replaced so the list never accumulates repeats.
    func remember(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        memories.removeAll { $0.text.caseInsensitiveCompare(text) == .orderedSame }
        memories.append(Memory(text: text))
        if memories.count > Self.maxMemories { memories.removeFirst(memories.count - Self.maxMemories) }
        AppLog.write("memory +: \(text)")
    }

    /// Removes memories matching the phrase (case-insensitive substring, either direction). Returns how many were dropped.
    @discardableResult
    func forget(_ phrase: String) -> Int {
        let q = phrase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return 0 }
        let before = memories.count
        memories.removeAll { let m = $0.text.lowercased(); return m.contains(q) || q.contains(m) }
        AppLog.write("memory -: \(phrase) (\(before - memories.count) removed)")
        return before - memories.count
    }

    func remove(_ id: Memory.ID) { memories.removeAll { $0.id == id } }
    func clearMemories() { memories = [] }
    func clearTurns() { turns = [] }

    func record(heard: String, said: String, action: String, task: String? = nil, project: String? = nil) {
        turns.append(ConversationTurn(heard: heard, said: said, action: action, task: task, project: project))
        if turns.count > Self.maxTurns { turns.removeFirst(turns.count - Self.maxTurns) }
    }

    /// Block for the orchestrator prompt.
    var promptSummary: String {
        memories.isEmpty ? "- (nothing saved yet)" : memories.map { "- \($0.text)" }.joined(separator: "\n")
    }

    /// Recent exchanges, oldest first, for the orchestrator prompt.
    var turnsSummary: String {
        guard !turns.isEmpty else { return "- (none)" }
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated
        return turns.map { t in
            var line = "- [\(f.localizedString(for: t.at, relativeTo: Date()))] heard: \"\(t.heard)\" → \(t.action)"
            if let p = t.project, !p.isEmpty { line += " project=\"\(p)\"" }
            if let k = t.task, !k.isEmpty { line += " task=\"\(k)\"" }
            if !t.said.isEmpty { line += " · said: \"\(t.said)\"" }
            return line
        }.joined(separator: "\n")
    }

    /// Text appended to coding-agent sessions so they honour the user's standing preferences.
    var agentGuidance: String? {
        memories.isEmpty ? nil :
        "Standing preferences the developer has told the assistant to remember (honour any that apply; ignore the rest):\n" + memories.map { "- \($0.text)" }.joined(separator: "\n")
    }
}
