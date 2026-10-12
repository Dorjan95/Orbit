import SwiftUI
import AppKit
import ServiceManagement

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, sessions, workflows, mascot, agents, voice, projects, memory
    var id: String { rawValue }
    var title: String {
        switch self { case .general: "Generale"; case .sessions: "Sessioni"; case .workflows: "Workflow"; case .mascot: "Mascotte"; case .agents: "Modelli"; case .voice: "Voce"; case .projects: "Progetti"; case .memory: "Memoria" }
    }
    var symbol: String {
        switch self { case .general: "slider.horizontal.3"; case .sessions: "rectangle.stack"; case .workflows: "point.3.connected.trianglepath.dotted"; case .mascot: "figure.wave"; case .agents: "cpu"; case .voice: "waveform"; case .projects: "folder"; case .memory: "brain" }
    }
    var detail: String {
        switch self {
        case .general: "Scorciatoie, ascolto e comportamento."
        case .sessions: "Segui i lavori sui tuoi progetti e continua le conversazioni."
        case .workflows: "Piano, modelli e percorsi di esecuzione."
        case .mascot: "Orbit Aero, il tuo compagno sul desktop."
        case .agents: "Scegli chi interpreta la voce e chi lavora sui progetti."
        case .voice: "La voce con cui Orbit ti risponde."
        case .projects: "Le cartelle su cui lavorare, riconosciute per nome."
        case .memory: "Preferenze e informazioni da ricordare."
        }
    }
}

struct SettingsView: View {
    @Bindable var coordinator: Coordinator
    @State var section: SettingsSection = .general
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Image(systemName: "waveform").font(.system(size: 23)).foregroundStyle(OrbitDesign.lime)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("ORBIT").font(.system(size: 17, weight: .heavy, design: .rounded)).tracking(1.3)
                        Text("IL TUO ASSISTENTE").font(.system(size: 8, weight: .bold)).tracking(1.1).foregroundStyle(OrbitDesign.secondaryText)
                    }
                }.padding(.bottom, 30).padding(.top, 16)
                ForEach(SettingsSection.allCases) { item in
                    Button { section = item } label: {
                        HStack(spacing: 10) {
                            Image(systemName: item.symbol).frame(width: 18)
                            Text(item.title).font(.system(size: 13, weight: .semibold))
                            Spacer()
                            if item == .sessions, !coordinator.sessions.activeVisible.isEmpty {
                                Text("\(coordinator.sessions.activeVisible.count)")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundStyle(OrbitDesign.lime)
                            }
                            if section == item { Rectangle().fill(OrbitDesign.lime).frame(width: 4, height: 4) }
                        }
                        .foregroundStyle(section == item ? OrbitDesign.chalk : OrbitDesign.secondaryText)
                        .padding(.horizontal, 12).frame(height: 42)
                        .background(section == item ? OrbitDesign.raisedSurface : .clear, in: RoundedRectangle(cornerRadius: 9))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                Spacer()
                HStack(spacing: 7) {
                    Rectangle().fill(OrbitDesign.lime).frame(width: 6, height: 6)
                    Text("PRONTO SUL TUO MAC").font(.system(size: 8, weight: .bold)).tracking(0.8)
                }.foregroundStyle(OrbitDesign.secondaryText)
                Text("Voce → progetto → risultato")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(OrbitDesign.tertiaryText).padding(.top, 5)
            }.padding(20).frame(width: 202).background(OrbitDesign.carbon)
            Rectangle().fill(OrbitDesign.line).frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(section.title.uppercased()).font(.system(size: 22, weight: .heavy, design: .rounded)).tracking(1)
                    Text(section.detail).font(.system(size: 12)).foregroundStyle(OrbitDesign.secondaryText)
                }.padding(.horizontal, 24).padding(.top, 26).padding(.bottom, 14)
                Group {
                    switch section {
                    case .general: GeneralTab(coordinator: coordinator)
                    case .sessions: SessionsTab(coordinator: coordinator)
                    case .workflows: WorkflowSettingsTab(coordinator: coordinator)
                    case .mascot: MascotTab(settings: coordinator.settings)
                    case .agents: AgentsTab(coordinator: coordinator)
                    case .voice: VoiceTab(coordinator: coordinator)
                    case .projects: ProjectsTab(registry: coordinator.registry, settings: coordinator.settings)
                    case .memory: MemoryTab(memory: coordinator.memory)
                    }
                }
                .scrollContentBackground(.hidden)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                AgentUsageFooter(coordinator: coordinator)
            }.frame(maxWidth: .infinity).background(OrbitDesign.screen)
        }
        .frame(width: 820, height: 680)
        .foregroundStyle(OrbitDesign.chalk).tint(OrbitDesign.lime).preferredColorScheme(.dark)
    }
}

struct GeneralTab: View {
    @Bindable var coordinator: Coordinator
    var body: some View {
        @Bindable var s = coordinator.settings
        Form {
            Section("Scorciatoie") {
                LabeledContent("Tieni premuto per parlare") { ShortcutRecorder(hotkey: $s.settings.pushToTalk) }
                LabeledContent("Mostra o nascondi le sessioni") { ShortcutRecorder(hotkey: $s.settings.overlayToggle) }
                if let e = coordinator.hotkeyError { Text(e).font(.caption).foregroundStyle(.red) }
            }
            Section("Lingua") {
                Picker("Lingua di dettatura", selection: $s.settings.speechLocale) {
                    Text("Italiano").tag("it-IT")
                    Text("English (US)").tag("en-US")
                }
                Text("Orbit ti capisce e ti risponde in questa lingua. La ricerca delle voci Fish segue la stessa scelta.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Comportamento") {
                Toggle("Apri all'avvio del Mac", isOn: Binding(get: { s.settings.launchAtLogin }, set: { v in
                    s.settings.launchAtLogin = v
                    do { if v { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch { s.settings.launchAtLogin = false }
                }))
                Toggle("Mostra sempre la barra flottante di Orbit", isOn: $s.settings.showIdlePill)
                Slider(value: $s.settings.overlayOpacity, in: 0.5...1) { Text("Opacità del pannello") }
                Toggle("Si attiva quando dici «Hey Orbit»", isOn: $s.settings.handsFree)
                    .help("Il microfono resta acceso e l'audio non esce dal Mac. Si spegne anche dal menu nella barra.")
                Toggle("Anche battendo due volte le mani", isOn: $s.settings.wakeOnClap).disabled(!s.settings.handsFree).padding(.leading, 16)
                    .help("Vale solo quando Orbit è in attesa, mai mentre parla o lavora. Dopo il battito dici la richiesta, senza il nome.")
                Toggle("Interrompilo parlando (cancellazione dell'eco, sperimentale)", isOn: $s.settings.echoCancellation).disabled(!s.settings.handsFree).padding(.leading, 16)
                    .help("Spento: mentre parla Orbit confronta quello che sente con quello che sta dicendo. Acceso: toglie la sua voce dal microfono, da provare con la tua voce.")
                Picker("Le richieste senza progetto partono da", selection: $s.settings.generalWorkspace) {
                    Text("Una cartella vuota").tag("")
                    ForEach(coordinator.registry.projects) { p in Text(p.name).tag(p.path) }
                }
                .help("Mail, calendario, domande: la sessione legge le istruzioni di quella cartella (per esempio AGENTS.md con Codex o CLAUDE.md del tuo vault di note, dove c'è scritto quale posta e quale calendario usi).")
                Toggle("Apri la pagina o il sito quando una sessione li ha fatti", isOn: $s.settings.openResults)
                Toggle("Aggiornamenti a voce mentre lavora", isOn: $s.settings.speakProgress)
                Toggle("Leggi a voce il riassunto quando una sessione finisce", isOn: $s.settings.speakSummaries)
                Toggle("Silenzioso quando è attiva una Full immersion", isOn: $s.settings.muteDuringFocus)
                Toggle("Suono breve quando premi la scorciatoia", isOn: $s.settings.blipOnChordDown)
            }
        }
        .formStyle(.grouped)
        .onChange(of: s.settings.pushToTalk) { coordinator.registerHotkeys() }
        .onChange(of: s.settings.handsFree) { coordinator.refreshWake() }
        .onChange(of: s.settings.echoCancellation) { coordinator.refreshWake() }
        .onChange(of: s.settings.wakeOnClap) { coordinator.refreshWake() }
        .onChange(of: s.settings.overlayToggle) { coordinator.registerHotkeys() }
    }
}

struct SessionsTab: View {
    @Bindable var coordinator: Coordinator
    @State private var creatingWorkflow = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Button("Nuovo workflow", systemImage: "arrow.triangle.branch") { creatingWorkflow = true }
                    Text("Esegui un percorso salvato su un progetto o nell’area Generale.").font(.caption).foregroundStyle(.secondary)
                }
                if coordinator.registry.projects.isEmpty {
                    Text("Puoi usare Generale anche senza registrare un progetto.").font(.caption).foregroundStyle(.secondary)
                }
                if !coordinator.sessions.finishedVisible.isEmpty {
                    HStack {
                        Spacer()
                        Button("Pulisci le concluse") { coordinator.clearHistory() }
                            .buttonStyle(PressableStyle())
                    }
                }
                SessionGroupsView(store: coordinator.sessions, chord: coordinator.settings.settings.pushToTalk,
                    onOpen: { coordinator.open(session: $0) }, onLog: { coordinator.showLog($0) },
                    onReply: { coordinator.followUp(session: $0, task: $1) },
                    onStop: { coordinator.stop(sessionID: $0.id) },
                    onDismiss: { coordinator.sessions.dismiss($0.id) },
                    onResumePending: { coordinator.resumePending(sessionID: $0.id) },
                    onApproval: { coordinator.resolveApproval(sessionID: $0.id, approvalID: $1, optionID: $2) },
                    onPlanDecision: { coordinator.decidePlan(sessionID: $0.id, approve: $1) },
                    onSteer: { coordinator.steer(sessionID: $0.id, task: $1) })
            }.padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 24)
        }
        .sheet(isPresented: $creatingWorkflow) { WorkflowLaunchView(coordinator: coordinator) }
    }
}

struct MascotTab: View {
    @Bindable var settings: SettingsStore
    @State private var previewPose: OrbitPose = .greeting
    @State private var previewStarted = Date()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Form {
            Section {
                HStack(spacing: 24) {
                    TimelineView(.animation(minimumInterval: settings.settings.mascotAnimations && !reduceMotion ? 1 / 60 : 1)) { context in
                        OrbitMascotFigure(pose: previewPose, elapsed: context.date.timeIntervalSince(previewStarted),
                            moving: settings.settings.mascotAnimations && !reduceMotion, modelHeight: 165,
                            clip: settings.settings.meshClip(for: previewPose), useDefault: false)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("ORBIT AERO").font(.system(size: 17, weight: .heavy, design: .rounded)).tracking(1)
                        Text("Ti saluta, si prepara ad ascoltare e reagisce a ciò che sta facendo.")
                            .font(.system(size: 12)).foregroundStyle(OrbitDesign.secondaryText)
                        Text("Trascinalo dove vuoi, anche su un altro schermo. La posizione viene ricordata.")
                            .font(.system(size: 12)).foregroundStyle(OrbitDesign.secondaryText)
                    }
                }.padding(.vertical, 8)
                Toggle("Mostra Orbit sul desktop", isOn: $settings.settings.mascotEnabled)
                Picker("Prova un gesto", selection: $previewPose) {
                    ForEach([OrbitPose.greeting, .listening, .thinking, .speaking, .working, .success, .clarify, .error], id: \.self) { pose in
                        Text(pose.label).tag(pose)
                    }
                }.onChange(of: previewPose) { previewStarted = Date() }
                Text("Scegli un gesto per vederlo in anteprima. Risposta mostra un fumetto, Domanda un punto interrogativo e Problema un triangolo di avviso sopra Orbit.")
                    .font(.caption).foregroundStyle(.secondary)
                Button { Orbit3DPreviewWindow.shared.show() } label: {
                    Label("Esplora le 12 animazioni in 3D", systemImage: "cube.transparent")
                }
            }
            Section("Animazioni per ogni stato") {
                ForEach(OrbitPose.configurableAnimations, id: \.self) { pose in
                    Picker(pose.label, selection: Binding(
                        get: { settings.settings.meshClip(for: pose)?.rawValue ?? "standing" },
                        set: { settings.settings.mascotClipAssignments[pose.rawValue] = $0; previewPose = pose; previewStarted = Date() }
                    )) {
                        Text("In piedi · senza movimento").tag("standing")
                        ForEach(OrbitMeshyClip.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
                    }
                }
                Text("Movimenti originali del modello Meshy. Ascolto e ragionamento si eseguono una volta e mantengono la posa finale. Durante il lavoro, camminata e corsa possono ripetersi.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Ripristina le animazioni predefinite") { settings.settings.mascotClipAssignments = [:]; previewStarted = Date() }
            }
            Section("Aspetto") {
                LabeledContent("Dimensione", value: "\(Int(settings.settings.mascotSize)) pt")
                Slider(value: $settings.settings.mascotSize, in: 120...320, step: 10) { Text("Dimensione di Orbit") }
                Toggle("Anima gesti e movimenti", isOn: $settings.settings.mascotAnimations)
                Toggle("Mostra lo stato di Orbit", isOn: $settings.settings.mascotShowStatus)
                Text("Le animazioni rispettano Riduci movimento di macOS.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Posizione e comandi") {
                Button("Riporta Orbit in basso a destra") { settings.settings.mascotOrigin = nil }
                Text("Un clic avvia l’ascolto: quando fai una pausa, Orbit invia la richiesta. Un secondo clic la invia subito; Esc annulla. Trascina per spostarlo, doppio clic per le sessioni, clic destro per le opzioni.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}

struct AgentsTab: View {
    @Bindable var coordinator: Coordinator
    @State private var claudeVersion = "…"
    @State private var codexVersion = "…"
    var body: some View {
        @Bindable var s = coordinator.settings
        Form {
            Section("Assistente") {
                Picker("Interpreta la voce e prepara i riassunti", selection: $s.settings.orchestratorAgent) { ForEach(AgentKind.interpreterCases) { Text($0.displayName).tag($0) } }
            }
            if s.settings.orchestratorAgent == .codex {
                ModelConnectionView(selection: $s.settings.codexAssistantSelection, cloudModel: $s.settings.codexOrchestratorModel,
                    title: "Comprensione e riassunti", detail: "Questo modello capisce su quale progetto lavorare e ti aggiorna sui risultati.")
            }
            ModelConnectionView(selection: $s.settings.codexWorkerSelection, cloudModel: $s.settings.codexModel,
                title: "Lavori con Codex", detail: "Questo modello legge i file, modifica il codice ed esegue i comandi nei progetti che usano Codex.", allowsIntegrations: true)
            Section("Sessioni e permessi") {
                Toggle("Controlli interattivi di Codex", isOn: $s.settings.codexInteractiveControls)
                Toggle("Controlli interattivi di Claude Code", isOn: $s.settings.claudeInteractiveControls)
                Text("Reindirizza il lavoro e rispondi ai permessi nella scheda della sessione. Usa i login delle CLI già presenti sul Mac. I controlli si applicano alle nuove sessioni; la review resta in sola lettura.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Agente predefinito", selection: $s.settings.defaultAgent) { ForEach(AgentKind.allCases) { Text($0.displayName).tag($0) } }
                Picker("Permessi di Claude", selection: $s.settings.claudePermissionMode) { ForEach(PermissionMode.allCases) { Text($0.displayName).tag($0) } }
                Picker("Permessi di Codex", selection: $s.settings.codexPermissionMode) { ForEach(PermissionMode.allCases) { Text($0.displayName).tag($0) } }
                Text("Con i controlli interattivi, Codex usa ‘Nel progetto’ e chiede i permessi aggiuntivi; Claude mostra le richieste della sua modalità standard. ‘Accesso completo’ evita le richieste previste dalle policy delle CLI.").font(.caption).foregroundStyle(.secondary)
                Stepper("Sessioni contemporanee al massimo: \(s.settings.maxConcurrentSessions)", value: $s.settings.maxConcurrentSessions, in: 1...6)
            }
            Section {
                DisclosureGroup("CLI trovate sul Mac") {
                    LabeledContent("claude") { Text(coordinator.claudePath.map { "\($0)  ·  \(claudeVersion)" } ?? "non trovato").font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    LabeledContent("codex") { Text(coordinator.codexPath.map { "\($0)  ·  \(codexVersion)" } ?? "non trovato").font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            if let p = coordinator.claudePath { claudeVersion = await CLILocator.version(of: p) ?? "?" }
            if let p = coordinator.codexPath { codexVersion = await CLILocator.version(of: p) ?? "?" }
        }
    }
}

struct VoiceTab: View {
    @Bindable var coordinator: Coordinator
    @State private var keyField = ""
    @State private var hasKey = Secrets.get(Secrets.fishKey) != nil
    @State private var balance: String = ""
    @State private var query = ""
    @State private var voices: [FishAudio.Voice] = []
    @State private var status = ""
    @State private var allLanguages = true
    @State private var isSearching = false
    @State private var hasSearched = false
    @State private var voiceStatus = ""
    @State private var page = 0
    @State private var hasMore = false
    @State private var searchTask: Task<Void, Never>?
    @State private var searchID = UUID()

    var body: some View {
        @Bindable var s = coordinator.settings
        Form {
            Section("Fish Audio") {
                if hasKey {
                    LabeledContent("Chiave API") {
                        HStack { Text("Salvata su questo Mac").foregroundStyle(.secondary); Button("Rimuovi") { Secrets.delete(Secrets.fishKey); hasKey = false; balance = ""; resetSearch() } }
                    }
                    LabeledContent("Crediti") { Text(balance.isEmpty ? "…" : balance).foregroundStyle(.secondary) }
                    Picker("Modello", selection: $s.settings.fishModel) {
                        Text("Automatico (Pro, gratuito se il credito API è finito)").tag("auto")
                        Text("S2.1 Pro, usa il credito API").tag("s2.1-pro")
                        Text("S2.1 Pro Free, gratuito").tag("s2.1-pro-free")
                    }
                    Text("I crediti del piano valgono solo sul sito di Fish. L'API scala un credito separato in dollari. Il modello Free non costa niente.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    LabeledContent("Chiave API") {
                        SecureField("Incolla la chiave di Fish Audio", text: $keyField)
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 260)
                            .onSubmit { saveKey() }
                    }
                    HStack {
                        Spacer()
                        Button("Salva") { saveKey() }.buttonStyle(.borderedProminent).foregroundStyle(.black).disabled(keyField.isEmpty)
                    }
                }
                if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }
            }
            Section("Voce") {
                HStack {
                    Text("In uso")
                    Spacer()
                    Text(s.settings.fishVoiceName).foregroundStyle(.secondary)
                    Button("Ascolta") { coordinator.voice.speak(VoiceService.sample(coordinator.settings.settings)) }
                        .help("Ascolta una frase con la voce attualmente selezionata")
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Cerca una voce")
                    HStack {
                        TextField("", text: $query, prompt: Text("Nome, link Fish Audio o ID"))
                            .labelsHidden().accessibilityLabel("Nome, link Fish Audio o ID").textFieldStyle(.roundedBorder)
                            .disabled(isSearching).onSubmit { search() }
                        Button("Cerca") { search() }.disabled(!hasKey || isSearching)
                    }
                }
                Picker("Lingua delle voci", selection: $allLanguages) {
                    Text("Tutte le lingue").tag(true)
                    Text("Solo lingua della dettatura (\(s.settings.voiceLanguageCode.uppercased()))").tag(false)
                }.disabled(isSearching)
                Text(hasKey ? "Hai trovato una voce sul sito? Incolla il suo link e premi Cerca. Il link cerca direttamente la voce, senza filtri di lingua." : "Salva la chiave API di Fish Audio per cercare o aggiungere una voce dal sito.")
                    .font(.caption).foregroundStyle(.secondary)
                if isSearching {
                    HStack { ProgressView().controlSize(.small); Text("Ricerca in corso…").foregroundStyle(.secondary) }
                } else if !voiceStatus.isEmpty {
                    Text(voiceStatus).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                } else if hasSearched && voices.isEmpty {
                    Text(allLanguages ? "Nessuna voce trovata. Prova il link della voce dal sito di Fish Audio." : "Nessuna voce trovata in questa lingua. Scegli Tutte le lingue oppure incolla il link della voce.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !voices.isEmpty {
                    List(voices) { v in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(v.title).lineLimit(1)
                                Text(([v.author].filter { !$0.isEmpty } + v.tags).joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if v.id == s.settings.fishVoiceID {
                                Label("In uso", systemImage: "checkmark").foregroundStyle(Color.accentColor)
                            } else {
                                Button("Usa") { s.settings.fishVoiceID = v.id; s.settings.fishVoiceName = v.title }
                                    .accessibilityLabel("Usa la voce \(v.title)")
                            }
                        }
                    }.frame(height: voices.count == 1 ? 70 : 180)
                }
                if hasMore {
                    Button("Mostra altre voci") { search(loadMore: true) }.disabled(isSearching || !hasKey)
                }
                Slider(value: $s.settings.speakingRate, in: 0.7...1.4) { Text("Velocità") }
                Toggle("Se Fish non risponde usa la voce di sistema", isOn: $s.settings.systemVoiceFallback)
            }
        }
        .formStyle(.grouped)
        .task { await refreshBalance() }
        .onChange(of: query) { resetSearch() }
        .onChange(of: allLanguages) { resetSearch() }
        .onChange(of: coordinator.settings.settings.voiceLanguageCode) { resetSearch() }
        .onDisappear { resetSearch() }
    }

    private func saveKey() {
        let k = keyField.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        if Secrets.set(k, for: Secrets.fishKey) { hasKey = true; keyField = ""; status = ""; Task { await refreshBalance() } }
        else { status = "Non riesco a salvare la chiave." }
    }

    private func refreshBalance() async {
        guard let key = Secrets.get(Secrets.fishKey) else { return }
        do { let b = try await FishAudio.balance(apiKey: key); balance = "Credito API $\(b.apiCreditUSD) · pacchetto \(b.balance.formatted()) (\(b.type))"; status = "" }
        catch { status = "Non riesco a leggere il saldo: \(error)" }
    }
    private func resetSearch() {
        searchTask?.cancel(); searchTask = nil; searchID = UUID()
        isSearching = false; hasSearched = false; voiceStatus = ""
        voices = []; page = 0; hasMore = false
    }

    private func search(loadMore: Bool = false) {
        guard !isSearching, let key = Secrets.get(Secrets.fishKey) else { return }
        let input = query
        let language = allLanguages ? nil : coordinator.settings.settings.voiceLanguageCode
        let nextPage = loadMore ? page + 1 : 1
        if !loadMore { voices = []; page = 0; hasMore = false }
        let id = UUID(); searchID = id
        isSearching = true; hasSearched = true; voiceStatus = ""
        searchTask = Task {
            defer { if searchID == id { isSearching = false; searchTask = nil } }
            do {
                let result: FishAudio.VoicePage
                switch try FishAudio.voiceInput(input) {
                case .reference(let voiceID):
                    result = FishAudio.VoicePage(voices: [try await FishAudio.voice(apiKey: key, id: voiceID)], hasMore: false)
                case .search(let title):
                    result = try await FishAudio.searchVoices(apiKey: key, query: title, language: language, page: nextPage)
                }
                guard !Task.isCancelled, searchID == id else { return }
                let existingIDs = Set(voices.map(\.id))
                voices += result.voices.filter { !existingIDs.contains($0.id) }
                page = nextPage; hasMore = result.hasMore
            } catch {
                guard !Task.isCancelled, searchID == id else { return }
                voiceStatus = FishAudio.voiceErrorMessage(error)
            }
        }
    }
}

struct ProjectsTab: View {
    @Bindable var registry: ProjectRegistry
    @Bindable var settings: SettingsStore
    @State private var selection: Project.ID?
    var body: some View {
        VStack(spacing: 8) {
            Table(registry.projects, selection: $selection) {
                TableColumn("Nome") { p in EditableText(text: binding(p, \.name)) }
                TableColumn("Percorso") { p in Text(p.path).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                TableColumn("Soprannomi") { p in
                    EditableText(text: Binding(get: { p.aliases.joined(separator: ", ") },
                                               set: { v in var q = p; q.aliases = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }; registry.update(q) }))
                }
                TableColumn("Agente") { p in
                    Picker("", selection: binding(p, \.defaultAgent)) { ForEach(AgentKind.allCases) { Text($0.displayName).tag($0) } }.labelsHidden()
                }.width(130)
                TableColumn("Permessi") { p in
                    HStack(spacing: 4) {
                        Picker("", selection: binding(p, \.permissionMode)) { ForEach(PermissionMode.allCases) { Text($0.displayName).tag($0) } }.labelsHidden()
                        if p.defaultAgent == .claude && p.permissionMode == .acceptEdits { Image(systemName: "hand.raised").foregroundStyle(.secondary).help("I comandi di shell verranno bloccati: le sessioni in background non possono approvare le richieste") }
                    }
                }.width(150)
            }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                for p in providers {
                    _ = p.loadObject(ofClass: URL.self) { url, _ in
                        guard let url, url.hasDirectoryPath else { return }
                        Task { @MainActor in registry.add(Project(name: ProjectRegistry.suggestedName(for: url), path: url.path, defaultAgent: settings.settings.defaultAgent, permissionMode: settings.settings.defaultPermissionMode)) }
                    }
                }
                return true
            }
            HStack {
                Button("+") { addFolder() }
                Button("−") { if let selection { registry.remove(selection) } }.disabled(selection == nil)
                Spacer()
                Text("Trascina qui una cartella per aggiungerla").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            HStack {
                Text("I progetti creati a voce vanno in").font(.caption).foregroundStyle(.secondary)
                TextField("~/Projects", text: $settings.settings.projectsRoot).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                Button("Scegli…") {
                    FolderPicker.choose(message: "Dove creo i progetti nuovi?") { settings.settings.projectsRoot = $0.path }
                }.controlSize(.small)
            }
            .padding(.horizontal, 12).padding(.bottom, 10)
        }
    }

    private func binding<T>(_ p: Project, _ kp: WritableKeyPath<Project, T>) -> Binding<T> {
        Binding(get: { registry.projects.first { $0.id == p.id }?[keyPath: kp] ?? p[keyPath: kp] },
                set: { v in var q = registry.projects.first { $0.id == p.id } ?? p; q[keyPath: kp] = v; registry.update(q) })
    }

    private func addFolder() {
        FolderPicker.choose { url in
            registry.add(Project(name: ProjectRegistry.suggestedName(for: url), path: url.path, defaultAgent: settings.settings.defaultAgent, permissionMode: settings.settings.defaultPermissionMode))
        }
    }
}

struct EditableText: View {
    @Binding var text: String
    var body: some View { TextField("", text: $text).textFieldStyle(.plain) }
}

/// Long-term memory: what Orbit has been told to remember, editable by hand.
struct MemoryTab: View {
    @Bindable var memory: MemoryStore
    @State private var draft = ""
    @State private var selection: Memory.ID?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Di' «ricordati che…» mentre parli oppure aggiungi una nota qui. L'orchestratore le legge a ogni turno e le passa a ogni agente che avvia.")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.top, 10)
            List(selection: $selection) {
                ForEach(memory.memories) { m in
                    HStack(alignment: .top) {
                        Text(m.text).textSelection(.enabled)
                        Spacer()
                        Text(m.createdAt, style: .date).font(.caption2).foregroundStyle(.tertiary)
                    }.tag(m.id)
                }
                if memory.memories.isEmpty { Text("Per ora non ricordo niente.").foregroundStyle(.tertiary) }
            }
            HStack {
                TextField("Aggiungi qualcosa da ricordare…", text: $draft).textFieldStyle(.roundedBorder).onSubmit(add)
                Button("Aggiungi", action: add).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("−") { if let selection { memory.remove(selection); self.selection = nil } }.disabled(selection == nil)
            }.padding(.horizontal, 12)
            HStack {
                Text("\(memory.turns.count) scambi recenti tenuti come contesto").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("Azzera la conversazione") { memory.clearTurns() }.controlSize(.small).disabled(memory.turns.isEmpty)
                Button("Dimentica tutto") { memory.clearMemories() }.controlSize(.small).disabled(memory.memories.isEmpty)
            }.padding(.horizontal, 12).padding(.bottom, 8)
        }
    }
    private func add() { memory.remember(draft); draft = "" }
}
