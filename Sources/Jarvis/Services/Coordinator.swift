import Foundation
import AppKit
import AVFoundation
import Observation

/// Central state machine (§2). Owns the services and drives the pill + overlay.
@MainActor @Observable
final class Coordinator {
    let usage: AgentUsageStore
    let settings: SettingsStore
    let registry: ProjectRegistry
    let sessions: SessionStore
    let memory: MemoryStore
    let speech: SpeechService
    let voice: VoiceService
    let pill = PillModel()

    private var runners: [String: any AgentBackend] = [:]
    private var clarifyContext: String?
    private var holdStart: Date?
    private var debounceTask: Task<Void, Never>?
    private var listeningActive = false
    private var mascotWakeCapture = false
    private var hideTask: Task<Void, Never>?
    private var blip: AVAudioPlayer?
    private var pttID: UInt32?
    private var overlayID: UInt32?
    private var escID: UInt32?
    /// Bumped by Esc so an in-flight orchestrator turn's result is dropped instead of spoken.
    private var turnGeneration = 0
    /// Per running session: the agent's latest short narration and when progress was last said out loud.
    private struct Progress { var narration = ""; var narrationAt = Date.distantPast; var spokenAt: Date?; var lastSaid = "" }
    private var progress: [String: Progress] = [:]
    private var progressLoop: Task<Void, Never>?
    let wake = WakeService()
    private var wakeConfig = ""
    private var askedWakePermissions = false

    var onPillChanged: (() -> Void)?

    private func pillDidChange() {
        onPillChanged?()
        syncEscapeHotkey()
    }

    /// Esc only exists as a hotkey while the pill is showing, so it never steals Esc from other apps.
    private func syncEscapeHotkey() {
        if pill.visible, escID == nil {
            escID = HotkeyMonitor.shared.register(Hotkey(keyCode: 53 /* kVK_Escape */, modifiers: 0), pressed: { [weak self] in self?.resetConversation() })
        } else if !pill.visible, let id = escID {
            HotkeyMonitor.shared.unregister(id); escID = nil
        }
    }

    /// Esc: abandon whatever is happening in the voice loop and start a fresh chat. Coding sessions are untouched.
    func resetConversation() {
        AppLog.write("escape: reset conversation")
        turnGeneration += 1
        voice.stop()
        if speech.isListening { Task { _ = await speech.stop() } }
        listeningActive = false; holdStart = nil
        debounceTask?.cancel(); debounceTask = nil
        hideTask?.cancel()
        mascotWakeCapture = false
        wake.stop()
        clarifyContext = nil
        memory.record(heard: "(ha premuto Esc: scambio annullato)", said: "", action: "cancelled", task: nil)
        pill.visible = false; pill.secondary = ""; pill.transcript = ""; pill.state = .listening
        pillDidChange()
        refreshWake()
    }

    /// Click to listen; another click submits. WakeService also submits after silence.
    func toggleMascotListening() {
        guard !listeningActive else { return }
        if wake.capturing { wake.finishFromMascot(); return }
        guard SpeechService.micStatus == .authorized, SpeechService.speechStatus == .authorized else {
            showError("Consenti microfono e riconoscimento vocale nelle Impostazioni di Sistema, poi clicca Orbit.")
            if SpeechService.micStatus == .notDetermined || SpeechService.speechStatus == .notDetermined {
                Task { _ = await SpeechService.requestPermissions() }
            }
            return
        }
        turnGeneration += 1
        mascotWakeCapture = true
        hideTask?.cancel()
        refreshWake()
        if !wake.captureFromMascot() {
            mascotWakeCapture = false
            showError("Il microfono non è disponibile. Controlla i permessi e riprova.")
            refreshWake()
        }
    }
    /// "Pulisci" in the sessions panel: the finished sessions go and so does the conversation, so the next request
    /// starts fresh instead of leaning on mails read "un attimo fa" (29/09). Saved memories stay.
    func clearHistory() {
        sessions.clearFinished()
        memory.clearTurns()
        clarifyContext = nil
        AppLog.write("history cleared")
    }
    var onOverlayToggle: (() -> Void)?
    var onLevelChanged: (() -> Void)?
    private(set) var hotkeyError: String?

    var claudePath: String? { CLILocator.find("claude", override: settings.settings.claudePathOverride) }
    var codexPath: String? { CLILocator.find("codex", override: settings.settings.codexPathOverride) }

    func executable(for agent: AgentKind) -> String? {
        switch agent { case .claude: claudePath; case .codex: codexPath; case .retiredDeepSeek: nil }
    }

    init(enableServices: Bool = true, sessionRoot: URL = AppPaths.root) {
        usage = AgentUsageStore(enabled: enableServices)
        Secrets.migrate()
        settings = SettingsStore()
        registry = ProjectRegistry()
        sessions = SessionStore(root: sessionRoot)
        memory = MemoryStore()
        speech = SpeechService()
        voice = VoiceService(settings: settings)
        voice.onFinished = { [weak self] in self?.didFinishSpeaking() }
        guard enableServices else { return }
        setUpWake()
        blip = try? AVAudioPlayer(data: Self.blipWAV()); blip?.volume = 0.35; blip?.prepareToPlay()
        registerHotkeys()
        Self.rotateLogs()
        progressLoop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                self?.tickProgress()
                self?.refreshWake()
            }
        }
    }

    // MARK: Hands-free ("Hey Orbit")

    private func setUpWake() {
        wake.echoText = { [weak self] in self?.voice.echoText ?? "" }
        wake.onWake = { [weak self] trigger in
            guard let self else { return }
            pill.automaticCapture = true
            AppLog.write("wake: \(trigger.rawValue)")
            // Talked over: pause, not stop, so a false alarm can resume where it was.
            if voice.isSpeaking { if trigger == .bargeIn { voice.pause(); pausedTranscript = pill.transcript } else { voice.stop() } }
            hideTask?.cancel()
            if settings.settings.blipOnChordDown { blip?.currentTime = 0; blip?.play() }
            pill.state = .listening; pill.transcript = ""; pill.secondary = ""; pill.fallbackBadge = false
            pill.visible = true; pillDidChange()
        }
        wake.onCaptureUpdate = { [weak self] text, level in
            guard let self else { return }
            pill.transcript = text; pill.level = level; onLevelChanged?(); pillDidChange()
        }
        wake.onNothingHeard = { [weak self] trigger in
            guard let self else { return }
            mascotWakeCapture = false
            if trigger == .bargeIn, voice.isPaused { resumeAfterFalseAlarm(); return }
            dismissPill(after: 0.3)
            refreshWake()
        }
        wake.onCommand = { [weak self] raw, trigger in
            guard let self else { return }
            mascotWakeCapture = false
            if trigger == .bargeIn, voice.isPaused {
                guard WakeService.isRealInterruption(raw) else { AppLog.write("wake: false alarm \"\(raw)\", resuming"); resumeAfterFalseAlarm(); return }
                voice.stop()
            }
            let text = Self.normalizeTranscript(raw)
            pill.state = .thinking; pill.transcript = text; pillDidChange()
            wake.setMode(.busy)
            refreshWake()
            Task { await self.handle(transcript: text); self.refreshWake() }
        }
        refreshWake()
    }

    private var pausedTranscript = ""
    private func resumeAfterFalseAlarm() {
        pill.state = .speaking; pill.transcript = pausedTranscript; pill.visible = true; pillDidChange()
        voice.resume()
        refreshWake()
    }

    /// Idempotent: runs every tick and after every state change. Off during push-to-talk (own audio engine),
    /// busy while Orbit thinks; while it talks, the user's words over it pause it.
    func refreshWake() {
        let s = settings.settings
        let want = (s.handsFree || mascotWakeCapture) && !listeningActive
        // Hands-free needs mic + speech up front: ask at once instead of waiting for a push-to-talk press
        // (after the signing certificate changed on 29/09 macOS treated Orbit as a new app and it just sat waiting).
        if want, !askedWakePermissions, SpeechService.micStatus == .notDetermined || SpeechService.speechStatus == .notDetermined {
            askedWakePermissions = true
            Task { let r = await SpeechService.requestPermissions(); AppLog.write("wake permissions: mic=\(r.mic) speech=\(r.speech)"); self.refreshWake() }
            return
        }
        let config = "\(s.speechLocale)|\(s.echoCancellation)"
        if wake.isRunning, (!want || config != wakeConfig) { wake.stop() }
        if want, !wake.isRunning {
            wakeConfig = config
            wake.start(locale: s.speechLocale, echoCancellation: s.echoCancellation)
        }
        wake.clapEnabled = s.wakeOnClap
        let thinking = pill.visible && pill.state == .thinking
        wake.setMode(thinking ? .busy : voice.isSpeaking ? .speaking : .idle)
    }

    // MARK: Progress updates

    /// First update after 20 s, then at most one every 45 s per session. Skips while you talk, while it is
    /// already speaking, during Focus, or with the toggle off. One session speaks per tick.
    private func tickProgress() {
        guard settings.settings.speakProgress, !listeningActive, !voice.isSpeaking,
              !(pill.visible && (pill.state == .thinking || pill.state == .clarify)),
              !(isDoNotDisturb && settings.settings.muteDuringFocus) else { return }
        let now = Date()
        let running = sessions.running.filter { $0.status == .running }
        for s in running.sorted(by: { (progress[$0.id]?.spokenAt ?? $0.startedAt) < (progress[$1.id]?.spokenAt ?? $1.startedAt) }) {
            var p = progress[s.id] ?? Progress()
            let due = p.spokenAt.map { now.timeIntervalSince($0) >= 45 } ?? (now.timeIntervalSince(s.startedAt) >= 20)
            guard due else { continue }
            var line: String?
            if !p.narration.isEmpty, p.narrationAt > (p.spokenAt ?? .distantPast) { line = p.narration }
            else if let phrase = ProgressSpeech.phrase(forActivity: s.activity) {
                line = "Sono a \(SessionStore.spoken(s.elapsed)), \(phrase)."
            }
            guard var text = line, text != p.lastSaid else { continue }
            if running.count > 1 { text = "\(s.projectName): \(text)" }
            p.spokenAt = now; p.lastSaid = line ?? text
            progress[s.id] = p
            AppLog.write("progress \(s.id): \(text)")
            pill.state = .speaking; pill.transcript = text; pill.secondary = ""; pill.visible = true; pillDidChange()
            voice.speak(text); pill.fallbackBadge = !voice.hasFishKey; pillDidChange()
            return
        }
    }

    /// Keep session logs for the sessions we still know about (≤100) and drop the rest.
    private static func rotateLogs() {
        let keep = Set((JSONStore.load([Session].self, from: AppPaths.sessions) ?? []).map { "\($0.id).ndjson" })
        let files = (try? FileManager.default.contentsOfDirectory(atPath: AppPaths.logs.path)) ?? []
        for f in files where f.hasSuffix(".ndjson") && !keep.contains(f) {
            try? FileManager.default.removeItem(at: AppPaths.logs.appendingPathComponent(f))
        }
    }

    // MARK: Hotkeys

    func registerHotkeys() {
        HotkeyMonitor.shared.unregister(pttID); HotkeyMonitor.shared.unregister(overlayID)
        pttID = HotkeyMonitor.shared.register(settings.settings.pushToTalk,
                                              pressed: { [weak self] in self?.chordDown() },
                                              released: { [weak self] in self?.chordUp() })
        overlayID = HotkeyMonitor.shared.register(settings.settings.overlayToggle, pressed: { [weak self] in self?.onOverlayToggle?() })
        AppLog.write("hotkeys: ptt=\(String(describing: pttID)) overlay=\(String(describing: overlayID))")
        hotkeyError = pttID == nil ? "\(settings.settings.pushToTalk.display) è già usata da un'altra app: cambiala nelle Impostazioni." : nil
    }

    func unregisterPushToTalk() { HotkeyMonitor.shared.unregister(pttID); pttID = nil }

    // MARK: Push-to-talk (§3.6 semantics)

    private func chordDown() {
        AppLog.write("chord down")
        holdStart = Date()
        if voice.isSpeaking { voice.stop() }   // barge-in
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled, holdStart != nil else { return }
            beginListening()
        }
    }

    private func chordUp() {
        AppLog.write("chord up (listening=\(listeningActive))")
        let started = holdStart; holdStart = nil
        debounceTask?.cancel(); debounceTask = nil
        guard let started, Date().timeIntervalSince(started) >= 0.15, listeningActive else { return }
        Task { await finishListening() }
    }

    private func beginListening() {
        listeningActive = true
        pill.automaticCapture = false
        mascotWakeCapture = false
        wake.stop()
        hideTask?.cancel()
        if settings.settings.blipOnChordDown { blip?.currentTime = 0; blip?.play() }
        pill.state = .listening; pill.transcript = ""; pill.secondary = clarifyContext ?? ""; pill.fallbackBadge = false
        pill.visible = true; pillDidChange()
        speech.start(locale: settings.settings.speechLocale)
        AppLog.write("stt start error=\(speech.error ?? "none") mic=\(SpeechService.micStatus.rawValue) speech=\(SpeechService.speechStatus.rawValue)")
        if let e = speech.error { showError(e); listeningActive = false; return }
        startLevelUpdates()
    }

    private func startLevelUpdates() {
        Task { @MainActor [weak self] in
            while let self, self.speech.isListening {
                self.pill.level = self.speech.level
                self.pill.transcript = self.speech.transcript
                self.onLevelChanged?()
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    /// Fix the mis-hearings that matter for routing before Haiku sees them.
    nonisolated static func normalizeTranscript(_ t: String) -> String {
        var s = t
        let fixes: [(String, String)] = [
            (#"\b(k|c)o[\s-]?de(x|cks|cs|ks|x's)\b"#, "Codex"), (#"\bcodecs?\b"#, "Codex"), (#"\bcode[\s-]?x\b"#, "Codex"), (#"\bcortex\b"#, "Codex"),
            (#"\bclaud\b"#, "Claude"), (#"\bclod\b"#, "Claude"), (#"\bcloud code\b"#, "Claude Code"), (#"\bcodice[\s-]?x\b"#, "Codex"), (#"\bcloud\b(?=\s+(to|and|should|can|will|code))"#, "Claude"),
        ]
        for (pat, rep) in fixes { s = s.replacingOccurrences(of: pat, with: rep, options: [.regularExpression, .caseInsensitive]) }
        return s
    }

    private func finishListening() async {
        listeningActive = false
        pill.state = .thinking; pillDidChange()
        let text = Self.normalizeTranscript(await speech.stop())
        AppLog.write("stt final: \"\(text)\"")
        pill.transcript = text; pillDidChange()
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { dismissPill(after: 0.6); refreshWake(); return }
        wake.setMode(.busy)
        await handle(transcript: text)
        refreshWake()
    }

    // MARK: Orchestration (§4)

    private var orchestratorTurn: Task<Void, Never>?

    var orchestrator: Orchestrator? {
        let agent = settings.settings.orchestratorAgent
        guard AgentKind.interpreterCases.contains(agent), let path = executable(for: agent) else { return nil }
        return Orchestrator(agent: agent, executable: path, defaultAgent: settings.settings.defaultAgent,
                            codexModel: settings.settings.codexOrchestratorModel, codexBackend: settings.settings.assistantBackend, language: settings.settings.replyLanguage)
    }

    func handle(transcript: String) async {
        guard orchestrator != nil else { showError("Non trovo la CLI di \(settings.settings.orchestratorAgent.displayName)"); return }
        // One orchestrator turn at a time — concurrent `claude -p` instances slow each other down.
        let previous = orchestratorTurn
        let turn = Task { @MainActor in await previous?.value; await self.handleSerialized(transcript: transcript) }
        orchestratorTurn = turn
        await turn.value
    }

    private func handleSerialized(transcript: String) async {
        let gen = turnGeneration
        guard let orch = orchestrator else { showError("L'agente vocale non è disponibile"); return }
        let action = await orch.decide(transcript: transcript, projects: registry.promptSummary, sessions: sessions.promptSummary,
                                       maxSessions: settings.settings.maxConcurrentSessions, runningCount: runners.count,
                                       context: clarifyContext, memories: memory.promptSummary, history: memory.turnsSummary)
        guard gen == turnGeneration else { AppLog.write("turn dropped (escaped): \"\(transcript)\""); return }
        let priorContext = clarifyContext
        clarifyContext = nil
        AppLog.write("transcript=\"\(transcript)\" → \(action)")
        await perform(action, transcript: priorContext.map { "\($0) / \(transcript)" } ?? transcript)
    }

    /// Haiku sometimes routes "open it on localhost / in the browser" to `open`, which pops a Terminal window.
    /// Only a literal folder/terminal/editor request may reach `open`; everything else becomes agent work.
    static func sanitize(_ raw: OrchestratorAction, transcript: String) -> OrchestratorAction {
        var a = raw
        // Haiku likes to "help" by naming a mailbox the user never said (29/09: "le ultime tre email" became
        // "…su <a Gmail address>", and the session went to Gmail instead of the user's real mailbox). Drop what wasn't said.
        if let t = a.task { a.task = stripUnsaidMail(t, transcript: transcript) }
        guard a.action == .open else { return a }
        let t = transcript.lowercased()
        let wantsShell = ["terminal", "finder", "folder", "directory", "editor", "vs code", "vscode", "cursor", "xcode",
                          "terminale", "cartella"].contains { t.contains($0) }
        let wantsWork = ["localhost", "browser", "port", "http", "run ", "serve", "preview", "deploy", "test", "start", "website", "site", "app",
                         "porta", "avvia", "lancia", "fai partire", "pubblica", "anteprima", "prova", "sito"].contains { t.contains($0) }
        if wantsShell && !wantsWork { return a }
        guard a.task != nil || wantsWork else { return a }   // bare "open X" with no work verbs: honour it
        var b = a
        b.action = .followup
        b.task = a.task ?? transcript
        b.sessionID = nil
        AppLog.write("sanitize: open → followup (\"\(transcript)\")")
        return b
    }

    nonisolated static func stripUnsaidMail(_ task: String, transcript: String) -> String {
        let heard = transcript.lowercased()
        var t = task
        if let re = try? NSRegularExpression(pattern: #"\s*\b(su|da|di|in|per|on|from)?\s*[\w.+-]+@[\w-]+(\.[\w-]+)+"#, options: [.caseInsensitive]) {
            for m in re.matches(in: t, range: NSRange(t.startIndex..., in: t)).reversed() {
                guard let r = Range(m.range, in: t) else { continue }
                let found = t[r].trimmingCharacters(in: .whitespaces).lowercased()
                if !found.split(separator: " ").contains(where: { $0.contains("@") && heard.contains($0) }) { t.removeSubrange(r) }
            }
        }
        for brand in ["gmail", "google mail", "outlook"] where !heard.contains(brand) {
            t = t.replacingOccurrences(of: #"\s*\b(su|di|in|da|on|from)?\s*"# + brand + #"\b"#, with: "", options: [.regularExpression, .caseInsensitive])
        }
        return t.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    func perform(_ raw: OrchestratorAction, transcript: String) async {
        let a = Self.sanitize(raw, transcript: transcript)
        // Memory side-effects happen regardless of which action was chosen.
        if let f = a.forget, !f.isEmpty { let n = memory.forget(f); if n == 0 && a.action == .chitchat { say("Non avevo niente di simile in memoria."); memory.record(heard: transcript, said: "niente da dimenticare", action: "forget"); return } }
        if let r = a.remember, !r.isEmpty { memory.remember(r) }
        var speak = a.speak
        switch a.action {
        case .steer:
            if let session = resolveSession(a.sessionID, project: a.project), let task = a.task {
                speak = steer(sessionID: session.id, task: task) ? "Interrompo il turno e riprendo con la nuova direzione." : "Non posso reindirizzare questa sessione adesso."
            } else { speak = "Non trovo la sessione da reindirizzare." }
        case .workflow:
            var definition = settings.settings.workflowDefinition
            guard let project = registry.resolve(a.project) ?? (a.project == nil ? generalProject() : nil), let task = a.task else {
                speak = "Scegli il progetto o l’area Generale in Sessioni, Nuovo workflow."; break
            }
            let command = project.verificationCommand ?? ""
            if definition.usesVerification && command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                speak = "Configura il comando di verifica in Sessioni, Nuovo workflow."; break
            }
            if let agent = a.agent, let index = definition.nodes.firstIndex(where: { $0.kind == .implementation || $0.kind == .action }) { definition.nodes[index].agent = agent }
            if !startWorkflow(project: project, agent: a.agent ?? project.defaultAgent, reviewer: .codex, task: task, verificationCommand: command, definition: definition) {
                speak = "Non sono riuscito ad avviare il workflow. Controlla le CLI e l’area di lavoro."
            } else { speak = definition.hasPlan ? "Avvio il piano del workflow. Ti chiederò di approvarlo, se previsto." : "Avvio il workflow configurato." }
        case .spawn:
            guard runners.count < settings.settings.maxConcurrentSessions else { speak = "Ho già \(runners.count) sessioni in corso. Aspettiamo che una finisca."; break }
            var resolved = registry.resolve(a.project) ?? (a.project == nil ? generalProject() : nil)
            // Unknown project name + a concrete task: create it on the spot rather than asking.
            if resolved == nil, let name = a.project, let task = a.task, !task.isEmpty, let made = try? createProject(named: name) {
                resolved = made
                if speak.isEmpty { speak = "Ho creato \(made.name), parto subito." }
            }
            guard let project = resolved else {
                clarifyContext = transcript
                pill.state = .clarify; pill.secondary = registry.projects.isEmpty ? "Nessun progetto: aggiungine uno nelle Impostazioni." : "Quale progetto?"
                speak = registry.projects.isEmpty ? "Non hai ancora aggiunto nessun progetto." : (a.speak.isEmpty ? "Su quale progetto?" : a.speak)
                break
            }
            guard let task = a.task, !task.isEmpty else { clarifyContext = transcript; pill.state = .clarify; speak = "Cosa deve fare?"; break }
            let agent = a.agent ?? project.defaultAgent
            if spawn(project: project, agent: agent, task: task, coding: a.coding) == false { speak = spawnFailureSpeech(project, agent) }
        case .followup:
            guard let task = a.task, !task.isEmpty else { speak = "Cosa deve fare?"; clarifyContext = transcript; pill.state = .clarify; break }
            if let s = resolveSession(a.sessionID, project: a.project) {
                if !followUp(session: s, task: task, coding: a.coding) { speak = lastFollowupFailure ?? "Non riesco a continuare questa sessione." }
            } else if let project = registry.resolve(a.project) {
                // No session for that project yet — a follow-up is just a spawn.
                if spawn(project: project, agent: a.agent ?? project.defaultAgent, task: task, coding: a.coding) == false { speak = spawnFailureSpeech(project, project.defaultAgent) }
                else if speak.isEmpty { speak = "Parto su \(project.name)." }
            } else {
                speak = "Su quale progetto?"; clarifyContext = transcript; pill.state = .clarify
            }
        case .cancel:
            if a.sessionID == "*" { stopAll(); break }
            guard let s = resolveSession(a.sessionID, project: a.project, runningOnly: true) else { speak = sessions.running.isEmpty ? "Non c'è niente in corso." : "Quale sessione?"; break }
            stop(sessionID: s.id)
        case .status:
            if speak.isEmpty { speak = statusSentence() }
        case .open:
            if let s = resolveSession(a.sessionID, project: a.project) { open(session: s) }
            else if let p = registry.resolve(a.project) { openTerminal(at: p.url) }
            else { speak = "Quale progetto?" }
        case .clarify:
            clarifyContext = transcript
            pill.state = .clarify; pill.secondary = VoiceService.stripCues(a.speak)
        case .chitchat:
            if speak.isEmpty, a.remember != nil { speak = "Ok, me lo ricordo." }
            if speak.isEmpty, a.forget != nil { speak = "Fatto, dimenticato." }
        case .create:
            guard let name = a.project?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
                clarifyContext = transcript; pill.state = .clarify; pill.secondary = "Come lo chiamo?"; speak = "Come chiamo il progetto?"; break
            }
            do {
                let project = try createProject(named: name)
                if let task = a.task, !task.isEmpty {
                    let agent = a.agent ?? settings.settings.defaultAgent
                    if spawn(project: project, agent: agent, task: task, coding: a.coding) == false { speak = spawnFailureSpeech(project, agent) }
                } else {
                    clarifyContext = transcript; pill.state = .clarify; pill.secondary = "Cosa ci costruisco?"
                    speak = "Ho creato \(project.name). Cosa ci costruisco dentro?"
                }
            } catch {
                speak = "Non sono riuscito a creare il progetto: \(error.localizedDescription)"
            }
        }
        memory.record(heard: transcript, said: speak, action: a.action.rawValue, task: a.task, project: a.project)
        say(speak)
    }

    /// Workspace for non-project requests ("riassumimi le mail", "cosa ho in calendario"). Best is a knowledge base
    /// such as a notes vault: the session reads its CLAUDE.md and memory, so it knows which mail and calendar the user
    /// has (on 29/09 a session in an empty folder went looking for Gmail). Falls back to an empty
    /// `<projectsRoot>/general` when no folder is chosen in Settings.
    func generalProject() -> Project? {
        let chosen = (settings.settings.generalWorkspace as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        if !chosen.isEmpty, FileManager.default.fileExists(atPath: chosen, isDirectory: &isDir), isDir.boolValue {
            if let p = registry.projects.first(where: { ($0.path as NSString).expandingTildeInPath == chosen }) { return p }
            return Project(name: URL(fileURLWithPath: chosen).lastPathComponent, path: chosen, defaultAgent: settings.settings.defaultAgent, permissionMode: settings.settings.defaultPermissionMode)
        }
        let root = URL(fileURLWithPath: (settings.settings.projectsRoot as NSString).expandingTildeInPath, isDirectory: true)
        let dir = root.appendingPathComponent("general", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else { return nil }
        return Project(name: "Generale", path: dir.path, aliases: ["generale", "general"], defaultAgent: settings.settings.defaultAgent, permissionMode: settings.settings.defaultPermissionMode)
    }

    private func spawnFailureSpeech(_ p: Project, _ agent: AgentKind) -> String {
        switch lastSpawnFailure {
        case .missingCLI: "La CLI di \(agent.displayName) non è installata."
        case .missingFolder: "La cartella di \(p.name) non esiste: correggi il percorso nelle Impostazioni."
        case .configuration(let message): message
        case .launch: "Non riesco ad avviare \(agent.displayName), guarda il log."
        case nil: "Non sono riuscito a farlo partire."
        }
    }

    private func resolveSession(_ id: String?, project: String?, runningOnly: Bool = false) -> Session? {
        if let id, let s = sessions.session(id) { return s }
        let pool = runningOnly ? sessions.running : sessions.visible
        if let p = registry.resolve(project), let s = pool.first(where: { $0.projectName == p.name }) { return s }
        return pool.count == 1 ? pool.first : nil
    }

    func statusSentence() -> String {
        let r = sessions.running
        if r.isEmpty { return "Al momento non c'è niente in corso." }
        return r.map { s in
            let doing = ProgressSpeech.phrase(forActivity: s.activity).map { ", \($0)" } ?? ""
            if let workflow = s.workflow, let stage = s.turns?.first(where: { $0.id == s.currentTurnID })?.workflowStage {
                return "\(s.projectName): \(stage.label.lowercased()) in corso\(doing), workflow \(workflow.state.rawValue)"
            }
            return "\(s.projectName): sono a \(SessionStore.spoken(s.elapsed))\(doing)"
        }.joined(separator: "; ") + "."
    }

    // MARK: Sessions

    enum SpawnFailure { case missingCLI, missingFolder, configuration(String), launch(String) }
    private(set) var lastSpawnFailure: SpawnFailure?

    /// Accept the full plan before starting either model. Review uses a fresh context.
    @discardableResult
    func startWorkflow(project: Project, agent: AgentKind, reviewer: AgentKind, task: String, verificationCommand: String, maxCorrections: Int? = nil, definition: WorkflowDefinition? = nil) -> Bool {
        guard agent.isAvailable, reviewer.isAvailable else {
            showError(AgentBackendError.removedAgent.localizedDescription); return false
        }
        let command = verificationCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !(definition?.usesVerification ?? true) || !command.isEmpty else {
            showError("Scrivi la richiesta e il comando di verifica del progetto."); return false
        }
        guard runners.count < settings.settings.maxConcurrentSessions else {
            showError("Attendi che una sessione termini."); return false
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: project.url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            showError("La cartella del progetto non esiste."); return false
        }
        if let definition {
            return startGraphWorkflow(project: project, task: task, command: command, definition: definition)
        }
        guard executable(for: agent) != nil, executable(for: reviewer) != nil else {
            showError("Installa o configura le CLI di implementazione e review."); return false
        }
        let implementationConfiguration = workflowConfiguration(project: project, agent: agent, readOnly: false)
        let reviewConfiguration = workflowConfiguration(project: project, agent: reviewer, readOnly: true)
        if let error = implementationConfiguration.codex?.configurationError ?? reviewConfiguration.codex?.configurationError {
            showError(error); return false
        }
        let implementation = SessionTurn(task: task, configuration: implementationConfiguration,
            guidance: memory.agentGuidance, workflowStage: .implementation)
        var review = SessionTurn(task: "Review", configuration: reviewConfiguration,
            guidance: "This is an independent read-only review. Do not open results or use connected services. The structured review report takes precedence over conversational final-answer instructions.", workflowStage: .review)
        review.task = AgentWorkflow.reviewTask(task: task, implementation: "", token: review.id)
        let verification = SessionTurn(task: command, configuration: implementationConfiguration, workflowStage: .verification)
        let session = Session(id: sessions.nextID(), projectName: project.name, projectPath: project.path, agent: agent,
            task: task, executionConfiguration: implementationConfiguration, turns: [implementation, review, verification],
            workflow: AgentWorkflow(originalTask: task, verificationCommand: command,
                maxCorrections: agent == .codex ? min(3, max(0, maxCorrections ?? 2)) : 0, correctionsScheduled: 0))
        do { try sessions.save(session, kind: .accepted, turnID: implementation.id) }
        catch { showError(error.localizedDescription); return false }
        return resumePending(sessionID: session.id)
    }

    func workflowConfiguration(project: Project, agent: AgentKind, readOnly: Bool) -> AgentExecutionConfiguration {
        AgentExecutionConfiguration(agent: agent,
            permissionMode: agent == project.defaultAgent ? project.permissionMode : settings.settings.permissionMode(for: agent),
            model: agent == .claude ? settings.settings.codingModel : agent == .codex ? settings.settings.codexModel : nil,
            codex: agent == .codex ? settings.settings.workerBackend : nil,
            readOnly: readOnly,
            interactiveControls: !readOnly && settings.settings.interactiveControls(for: agent))
    }

    @discardableResult
    func steer(sessionID: String, task: String) -> Bool {
        let direction = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !direction.isEmpty, var session = sessions.session(sessionID), session.offersSteering,
              let source = session.currentTurnID, let runner = runners[sessionID], runner.canSteer,
              let active = session.turns?.first(where: { $0.id == source }) else {
            showError("Reindirizzamento disponibile nelle sessioni con controlli interattivi, durante l'implementazione. Attendi l'avvio del turno."); return false
        }
        var replacement = SessionTurn(task: "Continue the interrupted task: \(session.workflow?.originalTask ?? active.task)\nNew direction from the user: \(direction)",
            configuration: active.configuration, guidance: active.guidance, workflowStage: active.workflowStage)
        replacement.workflowNodeID = active.workflowNodeID
        replacement.workflowAttempt = active.workflowAttempt
        replacement.repairSourceTurnID = active.repairSourceTurnID
        replacement.createdAt = Date()
        let insertion = session.turns!.firstIndex(where: { $0.id == source })! + 1
        session.turns!.insert(replacement, at: insertion)
        session.steering = SessionSteering(sourceTurnID: source, replacementTurnID: replacement.id)
        if let index = session.turns?.firstIndex(where: { $0.id == source }) { session.turns?[index].cancellationRequestedAt = Date() }
        session.workflow?.originalTask += "\nNuova direzione: " + direction
        session.activity = "Interrompe il turno per cambiare direzione…"
        session.approvals = session.approvals?.map {
            var value = $0
            if value.state == .pending { value.state = .expired; value.decidedAt = Date() }
            return value
        }
        session.status = .running
        do {
            try sessions.save(session, kind: .steeringRequested, turnID: source)
            try runner.interruptForSteering()
            return true
        } catch {
            // The accepted replacement is retained; uncertain delivery never causes automatic replay.
            runner.cancel(); showError(error.localizedDescription); return false
        }
    }

    @discardableResult
    func spawn(project: Project, agent: AgentKind, task: String, resume: String? = nil, existingID: String? = nil, coding: Bool? = nil, queuedTurnID: UUID? = nil) -> Bool {
        lastSpawnFailure = nil
        guard agent.isAvailable, existingID.flatMap({ sessions.session($0) })?.usesRetiredAgent != true else {
            lastSpawnFailure = .configuration(AgentBackendError.removedAgent.localizedDescription); return false
        }
        guard runners.count < settings.settings.maxConcurrentSessions,
              existingID.map({ runners[$0] == nil }) ?? true else {
            lastSpawnFailure = .configuration("Attendi che la sessione in corso termini."); return false
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: project.url.path, isDirectory: &isDir), isDir.boolValue else {
            lastSpawnFailure = .missingFolder
            AppLog.write("spawn refused: folder missing \(project.url.path)")
            return false
        }
        let previous = existingID.flatMap { sessions.session($0) }
        let queued = previous?.queuedTurns.first(where: { $0.id == queuedTurnID })
        if queuedTurnID != nil && queued == nil { return false }
        if let previous, previous.workflow != nil {
            guard let queued, previous.canResumeQueue, previous.queuedTurns.first?.id == queued.id else {
                lastSpawnFailure = .configuration("La fase precedente del workflow non è stata superata."); return false
            }
        }
        let exe: String
        if queued?.workflowStage == .verification || queued?.workflowStage == .command { exe = "/bin/zsh" }
        else if let path = executable(for: agent) { exe = path }
        else { lastSpawnFailure = .missingCLI; return false }
        let backend: CodexBackend? = agent == .codex
            ? (existingID == nil ? settings.settings.workerBackend : (sessions.session(existingID!)?.codexBackend ?? CodexBackend())) : nil
        if let message = (queued?.configuration.codex ?? backend)?.configurationError { lastSpawnFailure = .configuration(message); return false }
        let id = existingID ?? sessions.nextID()
        let mode = agent == project.defaultAgent ? project.permissionMode :
            settings.settings.permissionMode(for: agent)
        let model = agent == .codex ? settings.settings.codexModel :
            (agent == .claude && coding == true ? settings.settings.codingModel : nil)
        let configuration = queued?.configuration ?? previous?.executionConfiguration ??
            AgentExecutionConfiguration(agent: agent, permissionMode: mode, model: model, codex: backend,
                                        interactiveControls: settings.settings.interactiveControls(for: agent))
        var session = previous ?? Session(id: id, projectName: project.name, projectPath: project.path, agent: agent, task: task, codexBackend: backend)
        var turn = queued ?? SessionTurn(task: task, configuration: configuration, guidance: memory.agentGuidance)
        let turnID = turn.id
        let onEvent: @MainActor (AgentEvent) -> Void = { [weak self] e in self?.handleEvent(e, for: id, turnID: turnID) }
        let onExit: @MainActor (Int32, String) -> Void = { [weak self] code, text in self?.handleExit(code: code, lastText: text, for: id, turnID: turnID) }
        let runner: any AgentBackend
        if turn.workflowStage == .verification || turn.workflowStage == .command {
            runner = VerificationBackend(sessionID: id, onEvent: onEvent, onExit: onExit)
        } else if configuration.supportsInteractiveControls {
            runner = NativeAgentBackend(sessionID: id, agent: agent, onEvent: onEvent, onExit: onExit)
        } else { runner = AgentRunner(sessionID: id, agent: agent, onEvent: onEvent, onExit: onExit) }
        do {
            session.agent = configuration.agent
            session.executionConfiguration = configuration
            session.codexBackend = configuration.codex
            if queued == nil {
                session.turns = (session.turns ?? []) + [turn]
                try sessions.save(session, kind: .accepted, turnID: turnID)
            }
            // Persist the uncertain boundary before any external side effect.
            turn.state = .dispatched; turn.dispatchedAt = Date()
            session.turns = (session.turns ?? []).map { $0.id == turnID ? turn : $0 }
            session.currentTurnID = turnID
            session.workflow?.state = .dispatched
            if session.steering?.replacementTurnID == turnID { session.steering = nil }
            if turn.workflowStage == .planning || turn.workflowStage == .review || turn.workflowStage == .verification || turn.workflowStage == .command ||
                (turn.repairSourceTurnID != nil && resume == nil) { session.agentSessionID = nil }
            session.status = .running; session.task = turn.task; session.finishedAt = nil
            session.activity = ""; session.resultText = ""; session.startedAt = Date(); session.dismissed = false
            try sessions.save(session, kind: .dispatched, turnID: turnID)
            AppLog.write("spawn \(id) turn=\(turnID) provider=\(configuration.codex?.label ?? agent.displayName)")
            try runner.start(AgentRunRequest(executable: exe, task: turn.task, cwd: project.url.path, resume: resume,
                                             guidance: turn.guidance, configuration: configuration))
            runners[id] = runner
            session.pid = runner.pid
            try sessions.save(session, kind: .processStarted, turnID: turnID)
            return true
        } catch {
            runner.close()
            lastSpawnFailure = .launch("\(error)")
            sessions.update(id, event: .finished) {
                $0.workflow?.state = .failed; $0.workflow?.detail = "Avvio non riuscito: \(error)"
                $0.status = .failed; $0.finishedAt = Date(); $0.activity = "Avvio non riuscito: \(error)"
                if let index = $0.turns?.firstIndex(where: { $0.id == turnID }) {
                    $0.turns?[index].state = .failed; $0.turns?[index].finishedAt = Date()
                }
                if runners[id] == nil { $0.currentTurnID = nil; $0.pid = nil }
            }
            return false
        }
    }

    private(set) var lastFollowupFailure: String?

    @discardableResult
    func followUp(session s: Session, task: String, coding: Bool? = nil) -> Bool {
        lastFollowupFailure = nil
        guard var current = sessions.session(s.id), !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard !current.usesRetiredAgent else {
            lastFollowupFailure = AgentBackendError.removedAgent.localizedDescription
            showError(lastFollowupFailure!); return false
        }
        if current.workflow != nil {
            lastFollowupFailure = "Usa Reindirizza durante l'implementazione interattiva oppure avvia un nuovo workflow.";
            showError(lastFollowupFailure!); return false
        }
        let project = registry.projects.first(where: { $0.name == s.projectName }) ?? registry.resolve(s.projectName)
            ?? Project(name: s.projectName, path: s.projectPath, defaultAgent: s.agent,
                       permissionMode: settings.settings.permissionMode(for: s.agent))
        // Running or stopping processes retain ownership until their exit callback.
        if current.status == .cancelled && runners[s.id] != nil {
            lastFollowupFailure = "La sessione si sta fermando. Attendi prima di continuare."
            showError(lastFollowupFailure!); return false
        }
        let mode = s.agent == project.defaultAgent ? project.permissionMode :
            settings.settings.permissionMode(for: s.agent)
        let configuration = current.executionConfiguration ?? AgentExecutionConfiguration(agent: s.agent, permissionMode: mode,
            model: s.agent == .claude && coding == true ? settings.settings.codingModel : nil,
            codex: s.agent == .codex ? (current.codexBackend ?? CodexBackend()) : nil)
        let turn = SessionTurn(task: task, configuration: configuration, guidance: memory.agentGuidance)
        current.executionConfiguration = configuration
        current.turns = (current.turns ?? []) + [turn]
        current.dismissed = false
        if runners[s.id] != nil { current.activity = "Seguito in coda" }
        do { try sessions.save(current, kind: .accepted, turnID: turn.id) }
        catch { lastFollowupFailure = error.localizedDescription; showError(error.localizedDescription); return false }
        if runners[s.id] == nil { return resumePending(sessionID: s.id) }
        return true
    }

    @discardableResult
    func resumePending(sessionID: String) -> Bool {
        guard runners[sessionID] == nil, let session = sessions.session(sessionID), session.canResumeQueue, let next = session.queuedTurns.first else { return false }
        let project = Project(name: session.projectName, path: session.projectPath, defaultAgent: session.agent,
                              permissionMode: next.configuration.permissionMode)
        let freshContext = session.workflow?.definition != nil && session.steering?.replacementTurnID != next.id || next.workflowStage == .planning || next.workflowStage == .review || next.workflowStage == .verification || next.workflowStage == .command ||
            ((next.workflowAttempt ?? 0) > 0 && session.steering?.replacementTurnID != next.id)
        if !spawn(project: project, agent: next.configuration.agent, task: next.task, resume: freshContext ? nil : session.agentSessionID,
                  existingID: sessionID, queuedTurnID: next.id) {
            lastFollowupFailure = spawnFailureSpeech(project, session.agent)
            if sessions.session(sessionID)?.queuedTurns.contains(where: { $0.id == next.id }) == true {
                lastFollowupFailure! += " Il seguito resta in coda."
            }
            showError(lastFollowupFailure!)
            return false
        }
        return true
    }

    func stop(sessionID: String) {
        guard var session = sessions.session(sessionID) else { return }
        session.steering = nil; session.workflow?.awaitingPlanApproval = false; session.workflow?.state = .cancelled; session.workflow?.detail = "Workflow annullato"
        session.status = .cancelled; session.activity = runners[sessionID] == nil ? "" : "Mi sto fermando…"
        session.approvals = session.approvals?.map {
            var approval = $0
            if approval.state == .pending { approval.state = .cancelled; approval.decidedAt = Date() }
            return approval
        }
        if var turns = session.turns {
            for index in turns.indices where turns[index].state == .queued || turns[index].state == .dispatched {
                turns[index].cancellationRequestedAt = Date()
                if turns[index].state == .queued {
                    turns[index].state = .cancelled; turns[index].finishedAt = Date()
                }
            }
            session.turns = turns
        }
        if runners[sessionID] == nil { session.finishedAt = Date() }
        do { try sessions.save(session, kind: .cancelled, turnID: session.currentTurnID) }
        catch {
            // Cancellation must still stop the process when storage fails.
            sessions.update(sessionID) { $0 = session }
            showError(error.localizedDescription)
        }
        runners[sessionID]?.cancel()
    }

    /// The session, turn and current runtime must still own this exact request.
    /// Record the user's choice before delivering a one-shot grant to the peer.
    @discardableResult
    func resolveApproval(sessionID: String, approvalID: UUID, optionID: String) -> Bool {
        guard var session = sessions.session(sessionID), session.status == .needsInput,
              let turnID = session.currentTurnID, let runner = runners[sessionID], runner.isRunning,
              let index = session.approvals?.firstIndex(where: { $0.id == approvalID && $0.state == .pending && $0.turnID == turnID }),
              session.approvals?[index].options.contains(where: { $0.optionID == optionID && $0.isTransient }) == true else { return false }
        session.approvals?[index].state = .decided
        session.approvals?[index].selectedOptionID = optionID
        session.approvals?[index].decidedAt = Date()
        if session.pendingApprovals.isEmpty { session.status = .running; session.activity = "Riprende dopo la tua risposta" }
        do {
            try sessions.save(session, kind: .approvalDecided, turnID: turnID)
            try runner.resolveApproval(approvalID, optionID: optionID)
            return true
        } catch {
            // A failed delivery is uncertain; never retry the authorization.
            runner.cancel()
            showError(error.localizedDescription)
            return false
        }
    }

    func stopAll(includePendingPlans: Bool = true) {
        for session in sessions.sessions where runners[session.id] != nil || !session.queuedTurns.isEmpty || (includePendingPlans && session.workflow?.awaitingPlanApproval == true) { stop(sessionID: session.id) }
        for (_, runner) in runners { runner.close() }
    }

    private func handleEvent(_ e: AgentEvent, for id: String, turnID: UUID) {
        guard let session = sessions.session(id), session.currentTurnID == turnID, session.status != .cancelled else { return }
        switch e {
        case .approvalRequested(var approval):
            guard runners[id]?.capabilities.interactiveApprovals == true else { return }
            approval.turnID = turnID
            var updated = session
            updated.approvals = (updated.approvals ?? []) + [approval]
            updated.status = .needsInput; updated.activity = "In attesa di un permesso"
            do { try sessions.save(updated, kind: .approvalRequested, turnID: turnID) }
            catch { runners[id]?.cancel(); showError(error.localizedDescription) }
        case .approvalExpired(let approvalID):
            sessions.update(id, event: .approvalExpired) {
                if let index = $0.approvals?.firstIndex(where: { $0.id == approvalID && $0.state == .pending }) {
                    $0.approvals?[index].state = .expired; $0.approvals?[index].decidedAt = Date()
                }
                if $0.pendingApprovals.isEmpty && $0.status == .needsInput { $0.status = .running }
            }
        case .sessionID(let sid): sessions.update(id, event: .backendIdentified) { $0.agentSessionID = sid }
        case .activity(let a): sessions.update(id) { if $0.status == .running { $0.activity = a } }
        case .text(let t):
            sessions.update(id) { $0.resultText = String(t.suffix(4000)) }
            if let n = ProgressSpeech.narration(from: t) { progress[id, default: Progress()].narration = n; progress[id]?.narrationAt = Date() }
        case .needsInput: sessions.update(id, event: .blocked) { $0.status = .needsInput }
        case .streamComplete: break
        case .turnEnded(let outcome):
            sessions.update(id, event: .result) {
                if let index = $0.turns?.firstIndex(where: { $0.id == turnID }) { $0.turns?[index].backendOutcome = outcome }
                switch outcome {
                case .completed: break // Wait for stream flush and process exit.
                case .blocked:
                    $0.status = .needsInput
                    $0.activity = "\($0.agent.displayName) ha bloccato il turno"
                case .failed, .interrupted: $0.status = .failed
                case .cancelled: $0.status = .cancelled
                }
            }
        case .result(let t, let err):
            sessions.update(id, event: .result) {
                if !t.isEmpty { $0.resultText = String(t.suffix(4000)) }
                if err && $0.status != .needsInput {
                    $0.status = .failed
                }
            }
        }
    }

    private func handleExit(code: Int32, lastText: String, for id: String, turnID: UUID) {
        guard var s = sessions.session(id), s.currentTurnID == turnID else { return }
        AppLog.write("session \(id) exited \(code)")
        let steeringSettled = runners[id]?.steeringSettled == true && code == 0
        runners.removeValue(forKey: id)
        progress[id] = nil
        let wasCancelled = s.status == .cancelled
        s.approvals = s.approvals?.map {
            var approval = $0
            if approval.state == .pending { approval.state = .expired; approval.decidedAt = Date() }
            return approval
        }
        s.finishedAt = Date(); s.pid = nil; s.currentTurnID = nil
        if s.status == .running { s.status = code == 0 ? .done : .failed }
        if s.status == .needsInput && s.executionConfiguration?.supportsInteractiveControls == true { s.status = .failed }
        if s.status == .cancelled { s.activity = "" }
        if s.status == .failed && code != 0 && s.activity.isEmpty { s.activity = "Uscita \(code)" }
        if s.resultText.isEmpty { s.resultText = String(lastText.suffix(4000)) }
        if let index = s.turns?.firstIndex(where: { $0.id == turnID }) {
            let interrupted = s.turns?[index].backendOutcome == .interrupted
            s.turns?[index].state = interrupted ? .interrupted :
                s.status == .done ? .completed : s.status == .cancelled ? .cancelled : s.status == .needsInput ? .blocked : .failed
            s.turns?[index].finishedAt = Date(); s.turns?[index].exitCode = code
            s.turns?[index].resultText = String((lastText.isEmpty ? s.resultText : lastText).suffix(64000))
        }
        let steering = s.steering?.sourceTurnID == turnID
        if steering {
            s.workflow?.state = steeringSettled ? .dispatched : .interrupted
            s.status = .failed
            s.activity = steeringSettled ? "Riprende con la nuova direzione" : "Interruzione non confermata: controlla il lavoro e riprendi la coda."
            s.workflow?.detail = s.activity
        } else if s.workflow != nil {
            advanceWorkflow(&s, turnID: turnID, code: code)
        }
        do { try sessions.save(s, kind: .finished, turnID: turnID) }
        catch {
            s.status = .failed
            s.workflow?.state = .blocked
            s.workflow?.detail = "Salvataggio non riuscito. Nessuna nuova fase avviata: \(error.localizedDescription)"
            sessions.update(id) { $0 = s }; showError(error.localizedDescription); return
        }
        if steering {
            if steeringSettled { resumePending(sessionID: id) }
            return
        }
        if s.workflow != nil && s.canResumeQueue {
            resumePending(sessionID: id)
            return
        }
        if s.workflow == nil && s.status == .done && !s.queuedTurns.isEmpty {
            resumePending(sessionID: id)
            return
        }
        var opened: String?
        if !wasCancelled, s.status == .done, settings.settings.openResults,
           let log = try? String(contentsOf: AppPaths.log(for: id), encoding: .utf8),
           let url = SessionResult.viewable(ndjson: log, resultText: s.resultText.isEmpty ? lastText : s.resultText, projectPath: s.projectPath) {
            AppLog.write("open result \(id): \(url.absoluteString)")
            NSWorkspace.shared.open(url)
            opened = url.isFileURL ? url.lastPathComponent : url.absoluteString
        }
        guard !wasCancelled, settings.settings.speakSummaries, let orch = orchestrator else { return }
        let result = s.resultText.isEmpty ? lastText : s.resultText
        Task {
            let summary = await orch.summarize(task: s.task, project: s.projectName, result: result,
                                                                              isError: s.status != .done, exitCode: code, opened: opened)
            announce(summary)
        }
    }

    private func advanceWorkflow(_ session: inout Session, turnID: UUID, code: Int32) {
        if session.workflow?.definition != nil { advanceGraphWorkflow(&session, turnID: turnID, code: code); return }
        guard let turn = session.turns?.first(where: { $0.id == turnID }), let stage = turn.workflowStage,
              let workflow = session.workflow, (turn.workflowAttempt ?? 0) == workflow.attempt else { return }
        guard session.status == .done, code == 0, turn.state == .completed else {
            // Tool/auth failures, cancellation, signals and timeouts require human attention.
            let repairable = stage == .verification && (1...125).contains(code) &&
                turn.backendOutcome == .failed && session.status == .failed && turn.state == .failed
            if repairable && scheduleCorrection(&session, after: turn) { return }
            session.workflow?.state = session.status == .cancelled ? .cancelled : turn.state
            session.workflow?.detail = "\(stage.label) fermata: " + (session.activity.isEmpty ? "controlla il risultato e il log." : session.activity)
            finishFailedWorkflow(&session, budgetExhausted: repairable)
            return
        }
        switch stage {
        case .implementation:
            guard let index = session.turns?.firstIndex(where: {
                $0.workflowStage == .review && $0.state == .queued && ($0.workflowAttempt ?? 0) == workflow.attempt
            }), let token = session.turns?[index].id else {
                session.status = .failed; session.workflow?.state = .failed
                finishFailedWorkflow(&session, budgetExhausted: false); return
            }
            let failure = turn.repairSourceTurnID.flatMap { id in session.turns?.first(where: { $0.id == id }) }
            session.turns?[index].task = AgentWorkflow.reviewTask(task: workflow.originalTask,
                implementation: turn.resultText ?? "", token: token, previousFailure: failure.map(AgentWorkflow.failureEvidence) ?? "")
            session.workflow?.state = .dispatched; session.workflow?.detail = "Implementazione completata"
        case .review:
            guard let report = AgentWorkflow.reviewReport(turn.resultText ?? "", token: turnID) else {
                session.status = .failed; session.workflow?.state = .failed; session.workflow?.reviewPassed = false
                session.workflow?.detail = "Rapporto di review mancante o non valido. Verifica non eseguita."
                if let index = session.turns?.firstIndex(where: { $0.id == turnID }) { session.turns?[index].state = .failed }
                finishFailedWorkflow(&session, budgetExhausted: false); return
            }
            session.workflow?.reviewPassed = report.verdict == "passed"
            session.workflow?.detail = report.summary + (report.findings.isEmpty ? "" : "\n" + report.findings.joined(separator: "\n"))
            if report.verdict != "passed" {
                session.status = report.verdict == "blocked" ? .needsInput : .failed
                session.workflow?.state = report.verdict == "blocked" ? .blocked : .failed
                if let index = session.turns?.firstIndex(where: { $0.id == turnID }) { session.turns?[index].state = report.verdict == "blocked" ? .blocked : .failed }
                let repairable = report.verdict == "failed" && report.findings.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                if repairable && scheduleCorrection(&session, after: turn) { return }
                finishFailedWorkflow(&session, budgetExhausted: repairable)
            } else { session.workflow?.state = .dispatched }
        case .planning, .command, .action: return
        case .verification:
            session.workflow?.state = .completed; session.workflow?.detail = "Implementazione e review completate; comando di verifica riuscito."
            session.task = workflow.originalTask
        }
    }

    /// Mutates one snapshot; handleExit journals the complete plan before launching anything.
    private func scheduleCorrection(_ session: inout Session, after failure: SessionTurn) -> Bool {
        guard var workflow = session.workflow, workflow.attempt < workflow.correctionLimit,
              let initial = session.turns?.first(where: { $0.workflowStage == .implementation }),
              initial.configuration.agent == .codex, initial.configuration.readOnly != true,
              let review = session.turns?.first(where: { $0.workflowStage == .review }),
              session.turns?.contains(where: { $0.repairSourceTurnID == failure.id }) == false else { return false }
        let attempt = workflow.attempt + 1
        var correction = SessionTurn(task: AgentWorkflow.correctionTask(task: workflow.originalTask,
            evidence: AgentWorkflow.failureEvidence(failure), command: workflow.verificationCommand,
            attempt: attempt, limit: workflow.correctionLimit), configuration: initial.configuration,
            guidance: initial.guidance, workflowStage: .implementation)
        correction.workflowAttempt = attempt; correction.repairSourceTurnID = failure.id
        var newReview = SessionTurn(task: "Review", configuration: review.configuration,
            guidance: review.guidance, workflowStage: .review)
        newReview.workflowAttempt = attempt
        var verification = SessionTurn(task: workflow.verificationCommand, configuration: initial.configuration, workflowStage: .verification)
        verification.workflowAttempt = attempt
        for index in session.turns!.indices where session.turns![index].state == .queued {
            session.turns?[index].state = .cancelled; session.turns?[index].finishedAt = Date()
        }
        session.turns?.append(contentsOf: [correction, newReview, verification])
        workflow.correctionsScheduled = attempt; workflow.reviewPassed = nil; workflow.state = .dispatched
        workflow.detail = "\(failure.workflowStage!.label) non superata. Correzione Codex \(attempt) di \(workflow.correctionLimit)."
        session.workflow = workflow; session.status = .done; session.activity = workflow.detail
        session.task = workflow.originalTask
        return true
    }

    private func finishFailedWorkflow(_ session: inout Session, budgetExhausted: Bool) {
        guard let workflow = session.workflow else { return }
        session.task = workflow.originalTask
        if budgetExhausted && workflow.correctionLimit > 0 && workflow.attempt >= workflow.correctionLimit {
            let corrections = workflow.correctionLimit == 1 ? "correzione" : "correzioni"
            session.workflow?.detail += "\nLimite di \(workflow.correctionLimit) \(corrections) raggiunto. Controlla i risultati prima di avviare un nuovo workflow."
        }
        // Legacy workflows retain their original queue representation.
        if workflow.correctionLimit > 0 {
            for index in session.turns!.indices where session.turns![index].state == .queued {
                session.turns?[index].state = .cancelled; session.turns?[index].finishedAt = Date()
            }
        }
    }

    // MARK: Create

    struct CreateError: LocalizedError { let msg: String; var errorDescription: String? { msg } }

    /// Makes `<projectsRoot>/<slug>`, `git init`s it, and registers it (reuses an existing folder or registry entry).
    @discardableResult
    func createProject(named rawName: String) throws -> Project {
        let name = rawName.replacingOccurrences(of: #"\b(project|progetto)\b"#, with: "", options: [.regularExpression, .caseInsensitive]).trimmingCharacters(in: .whitespaces)
        let generic: Set<String> = ["", "new", "a new", "another", "untitled", "site", "website", "app", "thing", "one",
                                    "nuovo", "un nuovo", "nuova", "altro", "sito", "senza titolo", "cosa"]
        if generic.contains(name.lowercased()) { throw CreateError(msg: "mi serve un nome vero, come lo chiamo?") }
        if let existing = registry.projects.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame || $0.aliases.contains { $0.caseInsensitiveCompare(name) == .orderedSame } }) { return existing }
        let slug = name.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: "-")
        guard !slug.isEmpty else { throw CreateError(msg: "non ho capito il nome") }
        let root = URL(fileURLWithPath: (settings.settings.projectsRoot as NSString).expandingTildeInPath, isDirectory: true)
        let dir = root.appendingPathComponent(slug, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path), let git = CLILocator.find("git") {
            Task.detached { _ = await CLILocator.run(git, ["init", "-q"], cwd: dir.path, timeout: 20) }
        }
        let aliases = [slug.replacingOccurrences(of: "-", with: " ")].filter { $0 != name.lowercased() }
        let agent = settings.settings.defaultAgent
        let project = Project(name: name, path: dir.path, aliases: aliases, defaultAgent: agent,
                              permissionMode: settings.settings.permissionMode(for: agent))
        registry.add(project)
        AppLog.write("created project \(name) at \(dir.path)")
        return project
    }

    // MARK: Open

    func open(session s: Session) {
        let url = URL(fileURLWithPath: (s.projectPath as NSString).expandingTildeInPath)
        if s.usesRetiredAgent {
            openTerminal(at: url)
        } else if s.agent == .claude, let sid = s.agentSessionID, s.status != .running {
            openTerminal(at: url, command: "claude --resume \(sid)")
        } else if s.agent == .codex, let sid = s.agentSessionID, s.status != .running {
            let backend = s.codexBackend ?? CodexBackend()
            openTerminal(at: url, command: backend.resumeCommand(executable: codexPath ?? "codex", sessionID: sid))
        } else {
            openTerminal(at: url)
        }
    }

    func openTerminal(at url: URL, command: String? = nil) {
        let path = url.path.replacingOccurrences(of: "'", with: "'\\''")
        var script = "tell application \"Terminal\"\nactivate\ndo script \"cd '\(path)'"
        if let command { script += "; \(command.replacingOccurrences(of: "\"", with: "\\\""))" }
        script += "\"\nend tell"
        NSAppleScript(source: script)?.executeAndReturnError(nil)
    }

    func showLog(_ s: Session) { NSWorkspace.shared.open(AppPaths.log(for: s.id)) }

    // MARK: Voice / pill

    /// Replies are read aloud: bold markers, headings and bullets would be spoken or break the rhythm.
    nonisolated static func speakable(_ text: String) -> String {
        text.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: #"(?m)^\s*(#+|[-*•]|\d+\.)\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*\n+\s*"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func say(_ raw: String) {
        let text = Self.speakable(raw)
        AppLog.write("speak: \(text)")
        guard !text.isEmpty else { dismissPill(after: 0.25); return }
        if pill.state != .clarify { pill.state = .speaking }
        pill.transcript = VoiceService.stripCues(text)
        pill.visible = true; pillDidChange()
        if isDoNotDisturb && settings.settings.muteDuringFocus { dismissPill(after: 2.5); return }
        voice.speak(text)
        pill.fallbackBadge = !voice.hasFishKey
        pillDidChange()
    }

    /// Completion summaries: speak (unless DND) and flash the pill.
    func announce(_ text: String) {
        AppLog.write("announce: \(text)")
        pill.state = .speaking; pill.transcript = VoiceService.stripCues(text); pill.secondary = ""; pill.visible = true; pillDidChange()
        if isDoNotDisturb && settings.settings.muteDuringFocus { dismissPill(after: 3); return }
        voice.speak(text); pill.fallbackBadge = !voice.hasFishKey; pillDidChange()
    }

    private func didFinishSpeaking() {
        defer { refreshWake() }
        if pill.state == .clarify { dismissPill(after: 8) } else { dismissPill(after: 0.25) }
    }

    func showError(_ msg: String) {
        pill.state = .error; pill.transcript = pill.transcript.isEmpty ? "Non ho sentito" : pill.transcript; pill.secondary = msg
        pill.visible = true; pillDidChange()
        dismissPill(after: 3)
    }

    private func dismissPill(after s: TimeInterval) {
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(s))
            guard let self, !Task.isCancelled, !listeningActive, !wake.capturing else { return }
            pill.visible = false; pill.secondary = ""; pillDidChange()
        }
    }

    /// Best-effort Focus detection: macOS keeps Focus assertions in this per-user DB.
    var isDoNotDisturb: Bool {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/DoNotDisturb/DB/Assertions.json")
        guard let data = try? Data(contentsOf: url),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let records = (o["data"] as? [[String: Any]])?.first?["storeAssertionRecords"] as? [[String: Any]] else { return false }
        return !records.isEmpty
    }

    /// 40 ms 880 Hz sine with a half-sine envelope, as 16-bit mono WAV (§5.5 — no bundled asset needed).
    nonisolated static func blipWAV() -> Data {
        let sr = 44100, n = Int(0.04 * Double(sr))
        var pcm = Data(capacity: n * 2)
        for i in 0..<n {
            let env = sin(Double.pi * Double(i) / Double(n))
            let v = Int16(12000 * sin(2 * Double.pi * 880 * Double(i) / Double(sr)) * env)
            withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) }
        }
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + pcm.count)); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(sr)); u32(UInt32(sr * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count)); d.append(pcm)
        return d
    }

    // MARK: Quit

    func prepareForQuit() { wake.stop(); stopAll(includePendingPlans: false); LocalServerManager.shared.stop() }
}
