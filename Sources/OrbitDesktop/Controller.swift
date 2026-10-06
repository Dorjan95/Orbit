import AppKit
import Observation
import OrbitCore

@MainActor @Observable final class OrbitController {
  let disk: DiskStore
  var snapshot: Snapshot {
    didSet {
      persist()
      changed?()
    }
  }
  var phase: MascotState = .ready {
    didSet {
      if oldValue != phase { animationEpoch = Date() }
      changed?()
    }
  }
  var animationEpoch = Date()
  var transcript = ""
  var wakeStatus = "Ascolto non avviato"
  var wakeHeard = ""
  var voiceNeedsPermission = false
  var browserInstalling = false
  var prompts: [UUID: [AgentPrompt]] = [:]
  var integrationCatalog: [UUID: [ToolIntegration]] = [:]
  var catalog: [ToolIntegration] = []
  var catalogLoading = false
  var catalogError: String?
  var catalogLoaded = false
  var replying: Set<UUID> = []
  @ObservationIgnored private var codexSessions: [UUID: CodexSession] = [:]
  @ObservationIgnored private var catalogSession: CodexSession?
  @ObservationIgnored private lazy var browser = BrowserCoordinator(folder: disk.folder)
  var browserReady: Bool { settings.browserEnabled && BrowserSupport.ready(in: disk.folder) }
  var message = ""
  var error: String?
  var selectedSession: UUID?
  var section: Section = .general
  var isListening = false
  var isInterpreting = false
  var mainVisible = false
  var overlayRequested = false
  var migrationNotice: String?
  var changed: (() -> Void)?
  var openSettings: (() -> Void)?
  var audio: AudioCoordinator?
  private var processes: [UUID: ProcessStream] = [:]
  private var tasks: [UUID: Task<Void, Never>] = [:]
  private var pending: [UUID] = []
  private var routeTask: Task<Void, Never>?
  private var resetTask: Task<Void, Never>?
  private var saving = false
  init(disk: DiskStore = .standard, importLegacy: Bool = true) {
    self.disk = disk
    if FileManager.default.fileExists(atPath: disk.stateURL.path) {
      do { snapshot = try disk.read() } catch {
        snapshot = Snapshot()
        self.error =
          "Non riesco a leggere i dati Orbit. Il file originale è conservato; chiudi l’app e ripristinalo prima di salvare nuove impostazioni."
        saving = true  // A corrupted file must not be overwritten by defaults.
      }
    } else {
      let previous = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Jarvis")
      if importLegacy, disk.folder == DiskStore.standard.folder,
        let imported = try? ImportPreviousData.load(from: previous)
      {
        snapshot = imported
        migrationNotice =
          "Ho importato progetti, preferenze, memoria e sessioni nella nuova cartella Orbit. I dati precedenti sono conservati."
        let key = try? String(
          contentsOf: previous.appendingPathComponent("secrets/fish-audio-api-key"), encoding: .utf8
        )
        try? disk.setCredential(key)
      } else {
        snapshot = Snapshot()
      }
    }
    let previousWorkspace = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Jarvis/workspace")
    if importLegacy, disk.folder == DiskStore.standard.folder,
      snapshot.settings.generalDirectory == previousWorkspace.path
    {
      let destination = disk.folder.appendingPathComponent("workspace")
      do {
        try disk.prepare()
        if !FileManager.default.fileExists(atPath: destination.path) {
          if FileManager.default.fileExists(atPath: previousWorkspace.path) {
            try FileManager.default.copyItem(at: previousWorkspace, to: destination)
          } else {
            try FileManager.default.createDirectory(
              at: destination, withIntermediateDirectories: true)
          }
        }
        snapshot.settings.generalDirectory = destination.path
      } catch {
        self.error =
          "Non ho copiato la cartella di lavoro generale: \(error.localizedDescription). La cartella precedente è conservata."
      }
    }
    for i in snapshot.jobs.indices
    where snapshot.jobs[i].status == .running
      || (snapshot.jobs[i].status == .waiting && snapshot.jobs[i].finished == nil)
    {
      snapshot.jobs[i].status = .failed
      snapshot.jobs[i].activity = "Orbit è stato riaperto. Riprendi questa sessione per continuare."
    }
    persist()
  }
  var settings: Settings {
    get { snapshot.settings }
    set {
      if newValue.worker != snapshot.settings.worker
        || newValue.codexExecutable != snapshot.settings.codexExecutable
        || newValue.generalDirectory != snapshot.settings.generalDirectory
      {
        catalogSession?.cancel()
        catalogLoaded = false
        catalog = []
        catalogError = nil
      }
      snapshot.settings = newValue
      audio?.configure()
    }
  }
  var visibleJobs: [Job] { snapshot.jobs.filter { !$0.hidden }.sorted { $0.created > $1.created } }
  var activeCount: Int { visibleJobs.filter { $0.status.ongoing }.count }
  var speaking: Bool { audio?.speaking ?? false }
  func persist() {
    guard !saving else { return }
    do { try disk.write(snapshot) } catch {
      self.error = "Salvataggio non riuscito: \(error.localizedDescription)"
    }
  }
  func setPhase(_ value: MascotState, replay: Bool = false) {
    resetTask?.cancel()
    if replay { animationEpoch = Date() }
    phase = value
  }
  func rest(after seconds: Double = 4) {
    resetTask?.cancel()
    resetTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(seconds))
      guard !Task.isCancelled, let self, !isListening, !isInterpreting, !speaking else { return }
      phase =
        prompts.values.contains(where: { !$0.isEmpty })
        ? .question : processes.isEmpty ? .ready : .working
    }
  }
  func speak(_ text: String, state: MascotState = .responding, announcement: Bool = false) {
    if announcement && (isListening || isInterpreting || speaking) {
      if settings.announcements { audio?.say(text, announcement: true, state: state) }
      return
    }
    message = text
    setPhase(state)
    if !announcement || settings.announcements {
      audio?.say(text, announcement: announcement, state: state)
    }
    rest()
  }
  func beginListening() { audio?.beginCommand() }
  func finishListening() { audio?.finishCommand() }
  func cancelListening() {
    audio?.cancelCommand()
    routeTask?.cancel()
    isInterpreting = false
    phase = processes.isEmpty ? .ready : .working
  }
  func submit(_ text: String, session: UUID? = nil) {
    let request = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !request.isEmpty else { return }
    routeTask?.cancel()
    isInterpreting = false
    transcript = request
    if let id = session ?? selectedSession, let asks = prompts[id], !asks.isEmpty {
      answerByVoice(request, job: id, asks: asks)
      return
    }
    selectedSession = session ?? selectedSession
    isInterpreting = true
    setPhase(.thinking, replay: true)
    let state = snapshot
    let selected = selectedSession
    routeTask = Task { [weak self] in
      guard let self else { return }
      do {
        let decision = try await Routing.interpret(
          request, snapshot: state, selected: selected,
          browserAvailable: browserReady && settings.interpreter == .codex)
        guard !Task.isCancelled else { return }
        isInterpreting = false
        apply(decision, heard: request)
      } catch {
        guard !Task.isCancelled else { return }
        isInterpreting = false
        self.error = error.localizedDescription
        speak(error.localizedDescription, state: .problem)
      }
    }
  }
  func apply(_ decision: Decision, heard: String) {
    let project = snapshot.workspaces.first {
      $0.id.uuidString.caseInsensitiveCompare(decision.projectID ?? "") == .orderedSame
    }
    let session = snapshot.jobs.first {
      $0.id.uuidString.caseInsensitiveCompare(decision.sessionID ?? "") == .orderedSame
    }
    var reply = decision.reply
    switch decision.action {
    case .start:
      if let project {
        start(project, request: decision.task)
      } else if !settings.generalDirectory.isEmpty {
        var general = Workspace(
          name: "Generale", directory: settings.generalDirectory, agent: settings.interpreter)
        general.access = .project
        start(general, request: decision.task, general: true)
      } else {
        reply = "Scegli un progetto oppure imposta la cartella per le richieste generali."
        speak(reply, state: .question)
      }
    case .resume:
      if let session { continueJob(session.id, prompt: decision.task) }
    case .cancel:
      if let session {
        cancelJob(session.id)
        reply = "Ho fermato la sessione di \(session.workspaceName)."
        speak(reply)
      }
    case .status:
      if let session {
        selectedSession = session.id
        reply =
          "\(session.workspaceName): \(session.status.title). \(String(session.result.isEmpty ? session.activity.prefix(500) : session.result.suffix(700)))"
      } else {
        reply =
          visibleJobs.isEmpty
          ? "Non ci sono sessioni. Dimmi su quale progetto vuoi lavorare."
          : visibleJobs.prefix(6).map { "\($0.workspaceName): \($0.status.title)." }.joined(
            separator: " ")
      }
      speak(reply)
    case .remember:
      if let text = decision.memory, !text.isEmpty {
        snapshot.memories.append(text)
        reply = "Lo terrò a mente."
      }
      speak(reply)
    case .forget:
      if let text = decision.memory {
        snapshot.memories.removeAll { $0.caseInsensitiveCompare(text) == .orderedSame }
        reply = "Preferenza rimossa."
      }
      speak(reply)
    case .create:
      do {
        guard let name = decision.projectName,
          name.range(of: #"^[\p{L}\p{N}][\p{L}\p{N}_ -]{0,63}$"#, options: .regularExpression)
            != nil
        else {
          throw ServiceError(status: 0, message: "Scegli un nome semplice per il nuovo progetto.")
        }
        let root = URL(
          fileURLWithPath: (settings.newProjectsDirectory as NSString).expandingTildeInPath)
        let folder = root.appendingPathComponent(name, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: folder.path) else {
          throw ServiceError(
            status: 0,
            message: "Esiste già una cartella con questo nome. Aggiungila tra i progetti.")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let workspace = Workspace(name: name, directory: folder.path, agent: settings.interpreter)
        snapshot.workspaces.append(workspace)
        start(workspace, request: decision.task)
      } catch {
        reply = error.localizedDescription
        speak(reply, state: .problem)
      }
    case .reply:
      speak(
        reply.isEmpty ? "Dimmi su quale progetto vuoi lavorare." : reply,
        state: reply.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?")
          ? .question : .responding)
    }
    snapshot.conversation.append(Exchange(heard: heard, reply: reply.isEmpty ? message : reply))
    if snapshot.conversation.count > 200 {
      snapshot.conversation.removeFirst(snapshot.conversation.count - 200)
    }
  }
  func start(_ workspace: Workspace, request: String, general: Bool = false) {
    var job = Job(workspace: workspace, request: request, model: settings.worker)
    if general { job.workspaceID = nil }
    job.status = .waiting
    job.activity = "In coda"
    snapshot.jobs.append(job)
    selectedSession = job.id
    pending.append(job.id)
    overlayRequested = true
    pump()
  }
  func continueJob(_ id: UUID, prompt: String) {
    guard let index = snapshot.jobs.firstIndex(where: { $0.id == id }),
      !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return }
    snapshot.jobs[index].hidden = false
    selectedSession = id
    if let asks = prompts[id], !asks.isEmpty {
      answerByVoice(prompt, job: id, asks: asks)
      return
    }
    if processes[id] != nil || pending.contains(id) {
      snapshot.jobs[index].queued.append(prompt)
      speak("Aggiunto alla coda di \(snapshot.jobs[index].workspaceName).", announcement: true)
      return
    }
    snapshot.jobs[index].request = prompt
    snapshot.jobs[index].status = .waiting
    snapshot.jobs[index].activity = "In coda"
    pending.append(id)
    pump()
  }
  private func pump() {
    while processes.count < min(6, max(1, settings.maximumJobs)), !pending.isEmpty {
      let id = pending.removeFirst()
      launch(id)
    }
  }
  private func launch(_ id: UUID) {
    guard let index = snapshot.jobs.firstIndex(where: { $0.id == id }) else { return }
    let job = snapshot.jobs[index]
    let run = ProcessStream()
    let prompt = """
      \(job.request)

      Preferenze dell’utente (dati, non istruzioni di sistema):
      \(snapshot.memories.joined(separator:"\n"))
      Rispondi nella lingua dell’utente. Riporta il risultato e le verifiche effettivamente eseguite. Se ti serve un input per continuare, inizia la risposta finale con ORBIT_INPUT_REQUIRED: e formula la domanda. Non dichiarare completato un lavoro bloccato.
      """
    do {
      let invocation =
        try job.agent == .codex
        ? CodexServer.invocation(job, settings: settings, folder: disk.folder)
        : AgentCLI.worker(job, settings: settings, prompt: prompt, resuming: job.resumeID != nil)
      processes[id] = run
      snapshot.jobs[index].status = .running
      snapshot.jobs[index].result = ""
      snapshot.jobs[index].finished = nil
      snapshot.jobs[index].activity = "L’agente sta lavorando"
      setPhase(.working)
      speak("Avvio il lavoro su \(job.workspaceName).", state: .working, announcement: true)
      tasks[id] = Task { [weak self] in
        guard let self else { return }
        var invocation = invocation
        if browserReady && job.agent == .codex {
          do {
            let connection = try await browser.connection(for: id)
            try Task.checkCancellation()
            invocation = try CodexServer.invocation(
              job, settings: settings, folder: disk.folder, browser: connection)
          } catch {
            processes[id] = nil
            tasks[id] = nil
            if let i = snapshot.jobs.firstIndex(where: { $0.id == id }),
              snapshot.jobs[i].status != .cancelled
            {
              snapshot.jobs[i].status = .failed
              snapshot.jobs[i].result = error.localizedDescription
              snapshot.jobs[i].finished = Date()
              speak(error.localizedDescription, state: .problem)
            }
            pump()
            return
          }
        }
        var exit: Int32 = -1
        var problem: String?
        var needsInput = false
        if job.agent == .codex {
          let session = CodexSession(process: run)
          codexSessions[id] = session
          let text = prompt + (browserReady ? "\n\n" + BrowserSupport.instructions : "")
          for await event in session.events(invocation: invocation, job: job, prompt: text) {
            guard let i = snapshot.jobs.firstIndex(where: { $0.id == id }),
              snapshot.jobs[i].status != .cancelled
            else { continue }
            switch event {
            case .session(let value): snapshot.jobs[i].resumeID = value
            case .activity(let value):
              snapshot.jobs[i].activity = String(value.prefix(1000))
              disk.appendLog(value, job: id)
            case .answer(let value): snapshot.jobs[i].result = value
            case .diagnostic(let value): disk.appendLog(value, job: id)
            case .integrations(let value): integrationCatalog[id] = value
            case .request(let ask):
              prompts[id, default: []].append(ask)
              snapshot.jobs[i].status = .waiting
              snapshot.jobs[i].activity = ask.title
              overlayRequested = true
              message = "\(job.workspaceName): \(ask.title)"
              setPhase(.question)
              speak(
                message + ". Apri Sessioni per rispondere.", state: .question, announcement: true)
            case .resolved(let requestID):
              prompts[id]?.removeAll { $0.id == requestID }
              if prompts[id]?.isEmpty != false {
                snapshot.jobs[i].status = .running
                snapshot.jobs[i].activity = "L’agente sta lavorando"
              }
            case .finished(let value):
              problem = value
              exit = value == nil ? 0 : 1
            }
          }
          codexSessions[id] = nil
          prompts[id] = nil
        } else {
          for await event in run.events(for: invocation) {
            guard let i = snapshot.jobs.firstIndex(where: { $0.id == id }) else { break }
            switch event {
            case .started: break
            case .output(let line):
              disk.appendLog(line, job: id)
              for decoded in EventDecoder.decode(line, agent: job.agent) {
                switch decoded {
                case .session(let value): snapshot.jobs[i].resumeID = value
                case .activity(let value): snapshot.jobs[i].activity = String(value.prefix(1000))
                case .answer(let value): snapshot.jobs[i].result = value
                case .inputNeeded(let value):
                  snapshot.jobs[i].result = value
                  needsInput = true
                case .problem(let value): problem = value
                }
              }
            case .diagnostic(let line):
              disk.appendLog(line, job: id)
              if !line.isEmpty { snapshot.jobs[i].activity = String(line.prefix(700)) }
            case .finished(let code): exit = code
            case .failed(let value): problem = value
            }
          }
        }
        processes[id] = nil
        tasks[id] = nil
        guard let i = snapshot.jobs.firstIndex(where: { $0.id == id }) else {
          pump()
          return
        }
        if snapshot.jobs[i].status != .cancelled {
          let text = snapshot.jobs[i].result
          if text.hasPrefix("ORBIT_INPUT_REQUIRED:") {
            needsInput = true
            snapshot.jobs[i].result = text.replacingOccurrences(
              of: "ORBIT_INPUT_REQUIRED:", with: ""
            ).trimmingCharacters(in: .whitespacesAndNewlines)
          }
          needsInput = needsInput && exit == 0 && problem == nil
          snapshot.jobs[i].status =
            exit != 0 || problem != nil ? .failed : needsInput ? .waiting : .completed
          if let problem, !snapshot.jobs[i].result.isEmpty {
            snapshot.jobs[i].result += "\n\nErrore: " + problem
          }
          snapshot.jobs[i].finished = Date()
          snapshot.jobs[i].activity = problem ?? snapshot.jobs[i].status.title
          if snapshot.jobs[i].result.isEmpty {
            snapshot.jobs[i].result =
              problem ?? "L’agente è terminato con codice \(exit). Apri il log per i dettagli."
          }
          let final = snapshot.jobs[i]
          message = "\(final.workspaceName): \(final.status.title)"
          setPhase(needsInput ? .question : final.status == .completed ? .success : .problem)
          if settings.summaries {
            speak(
              "\(final.workspaceName). \(String(final.result.prefix(650)))", state: phase,
              announcement: true)
          }
          if final.status == .completed, settings.openResults { openLink(in: final.result) }
          if !needsInput, final.status == .completed, !final.queued.isEmpty {
            let next = snapshot.jobs[i].queued.removeFirst()
            continueJob(id, prompt: next)
          }
        }
        pump()
        rest(after: 6)
      }
    } catch {
      snapshot.jobs[index].status = .failed
      snapshot.jobs[index].result = error.localizedDescription
      speak(error.localizedDescription, state: .problem)
    }
  }
  func cancelJob(_ id: UUID) {
    pending.removeAll { $0 == id }
    codexSessions[id]?.cancel()
    prompts[id] = nil
    processes[id]?.cancel()
    if let i = snapshot.jobs.firstIndex(where: { $0.id == id }) {
      snapshot.jobs[i].status = .cancelled
      snapshot.jobs[i].queued = []
      snapshot.jobs[i].finished = Date()
    }
  }
  func dismissJob(_ id: UUID) {
    if let i = snapshot.jobs.firstIndex(where: { $0.id == id }), !snapshot.jobs[i].status.ongoing {
      snapshot.jobs[i].hidden = true
      browser.close(id)
    }
  }
  func clearFinished() {
    for i in snapshot.jobs.indices where !snapshot.jobs[i].status.ongoing {
      snapshot.jobs[i].hidden = true
      browser.close(snapshot.jobs[i].id)
    }
  }
  func respond(
    _ job: UUID, request: JSONValue, accept: Bool, answers: [String: String] = [:],
    form: JSONValue = [:]
  ) {
    guard !replying.contains(job), let session = codexSessions[job],
      prompts[job]?.contains(where: { $0.id == request }) == true
    else { return }
    replying.insert(job)
    Task {
      defer { replying.remove(job) }
      do { try await session.respond(request, accept: accept, answers: answers, form: form) } catch
      { self.error = error.localizedDescription }
    }
  }
  private func answerByVoice(_ text: String, job: UUID, asks: [AgentPrompt]) {
    guard asks.count == 1, let ask = asks.first else {
      speak(
        "Ci sono più richieste aperte in questa sessione. Rispondi dal pannello Sessioni.",
        state: .question)
      return
    }
    selectedSession = job
    if ask.kind == .questions, ask.questions.count == 1, let question = ask.questions.first,
      !question.secret
    {
      respond(job, request: ask.id, accept: true, answers: [question.id: text])
      return
    }
    let normalized = text.lowercased().trimmingCharacters(
      in: .whitespacesAndNewlines.union(.punctuationCharacters))
    if ["rifiuta", "non approvare", "annulla richiesta"].contains(normalized) {
      respond(job, request: ask.id, accept: false)
    } else if [.command, .files, .permissions].contains(ask.kind),
      ["approva", "autorizza"].contains(normalized)
    {
      respond(job, request: ask.id, accept: true)
    } else {
      speak(
        "\(ask.title). Leggi la richiesta in Sessioni e usa i pulsanti, oppure di’ approva o rifiuta per questa autorizzazione.",
        state: .question)
    }
  }
  func refreshIntegrations() {
    guard !catalogLoading else { return }
    catalogLoading = true
    catalogError = nil
    let choice = settings.worker
    let executable = settings.codexExecutable
    let general = settings.generalDirectory
    Task {
      defer {
        catalogLoading = false
        catalogSession = nil
      }
      do {
        let directory = (settings.generalDirectory as NSString).expandingTildeInPath
        let job = Job(
          workspace: Workspace(name: "Connessioni", directory: directory), request: "",
          model: settings.worker)
        let invocation = try CodexServer.invocation(job, settings: settings, folder: disk.folder)
        let session = CodexSession()
        catalogSession = session
        for await event in session.events(
          invocation: invocation, job: job, prompt: "", inspectOnly: true)
        {
          guard settings.worker == choice, settings.codexExecutable == executable,
            settings.generalDirectory == general
          else { continue }
          switch event {
          case .integrations(let value):
            catalog = value
            catalogLoaded = true
          case .finished(let failure): if let failure { catalogError = failure }
          case .diagnostic(let value):
            if value.contains("autenticazione") { catalogError = value }
          default: break
          }
        }
        // Inspection does not create a local conversation to retain.
        if job.model.provider.local && !job.model.integrations {
          try? FileManager.default.removeItem(
            at: disk.folder.appendingPathComponent("codex-local/\(job.id.uuidString)"))
        }
      } catch { catalogError = error.localizedDescription }
    }
  }
  func installBrowser() {
    guard !browserInstalling else { return }
    browserInstalling = true
    Task {
      defer { browserInstalling = false }
      do {
        try await browser.install()
        settings.browserEnabled = true
        error = nil
      } catch { self.error = error.localizedDescription }
    }
  }
  func showBrowser(_ id: UUID) {
    Task {
      do { try await browser.show(id) } catch { self.error = error.localizedDescription }
    }
  }
  func openLog(_ job: Job) {
    guard FileManager.default.fileExists(atPath: disk.logURL(job.id).path) else {
      error = "Il log non è disponibile per questa sessione importata."
      return
    }
    NSWorkspace.shared.open(disk.logURL(job.id))
  }
  func openTerminal(_ job: Job) {
    func quote(_ value: String) -> String {
      "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    let invocation: Invocation
    do { invocation = try AgentCLI.interactive(job, settings: settings) } catch {
      self.error = error.localizedDescription
      return
    }
    let localHome = disk.folder.appendingPathComponent("codex-local/\(job.id.uuidString)")
    let environment =
      job.agent == .codex && job.model.provider.local && !job.model.integrations
        && FileManager.default.fileExists(atPath: localHome.path)
      ? "env CODEX_HOME=\(quote(localHome.path)) " : ""
    let command =
      "#!/bin/zsh\ncd -- \(quote(invocation.directory.path)) || exit 1\nexec \(environment)\(quote(invocation.executable.path)) \(invocation.arguments.map(quote).joined(separator: " "))\n"
    let file = disk.folder.appendingPathComponent("terminal-\(job.id).command")
    do {
      try Data(command.utf8).write(to: file)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
      NSWorkspace.shared.open(file)
    } catch { self.error = error.localizedDescription }
  }
  private func openLink(in text: String) {
    guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    else { return }
    for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
      guard let url = match.url, ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
        url.user == nil, url.password == nil
      else { continue }
      NSWorkspace.shared.open(url)
      return
    }
  }
  func shutdown() {
    routeTask?.cancel()
    catalogSession?.cancel()
    for session in codexSessions.values { session.cancel() }
    browser.stop()
    audio?.stop()
    for process in processes.values { process.cancel() }
    persist()
  }
}
enum Section: String, CaseIterable, Identifiable {
  case general = "Generale"
  case sessions = "Sessioni"
  case mascot = "Mascotte"
  case models = "Modelli"
  case voice = "Voce"
  case projects = "Progetti"
  case memory = "Memoria"
  var id: String { rawValue }
  var symbol: String {
    switch self {
    case .general: "slider.horizontal.3"
    case .sessions: "rectangle.stack"
    case .mascot: "figure.stand"
    case .models: "cpu"
    case .voice: "waveform"
    case .projects: "folder"
    case .memory: "brain.head.profile"
    }
  }
  var subtitle: String {
    switch self {
    case .general: "Scorciatoie, ascolto e comportamento."
    case .sessions: "Ogni progetto ha il suo contesto."
    case .mascot: "Aero ti accompagna, dove preferisci."
    case .models: "Scegli chi interpreta e chi lavora."
    case .voice: "Una voce per il tuo assistente."
    case .projects: "Le cartelle su cui vuoi lavorare."
    case .memory: "Le preferenze che Orbit ricorda per te."
    }
  }
}
