@preconcurrency import AVFoundation
import AppKit
import OrbitCore
import SwiftUI

struct ProjectsView: View {
  @Bindable var controller: OrbitController
  @State private var editing: Workspace?
  var body: some View {
    VStack(spacing: 17) {
      HStack {
        Text("\(controller.snapshot.workspaces.count) progetti").foregroundStyle(Palette.muted)
        Spacer()
        Button {
          let p = NSOpenPanel()
          p.canChooseDirectories = true
          p.canChooseFiles = false
          if p.runModal() == .OK, let url = p.url {
            editing = Workspace(name: url.lastPathComponent, directory: url.path)
          }
        } label: {
          Label("Aggiungi cartella", systemImage: "plus")
        }.buttonStyle(.borderedProminent)
      }
      if controller.snapshot.workspaces.isEmpty {
        Card {
          Image(systemName: "folder.badge.plus").font(.system(size: 32)).foregroundStyle(
            Palette.accent)
          Text("Il tuo primo progetto").font(.system(size: 18, weight: .bold))
          Text(
            "Aggiungi la cartella di una repository e i nomi con cui la chiami a voce. Puoi lavorare su più progetti contemporaneamente."
          ).foregroundStyle(Palette.muted).font(.system(size: 13))
        }
      }
      ForEach(controller.snapshot.workspaces) { project in
        Card {
          HStack {
            Image(systemName: "folder").foregroundStyle(Palette.accent)
            Text(project.name).fontWeight(.bold)
            Spacer()
            Button("Modifica") { editing = project }
            Button {
              controller.snapshot.workspaces.removeAll { $0.id == project.id }
            } label: {
              Image(systemName: "trash")
            }.disabled(
              controller.snapshot.jobs.contains {
                $0.workspaceID == project.id && $0.status.ongoing
              }
            ).help("Rimuovi dalla lista")
          }
          Text(project.directory).font(.system(size: 11, design: .monospaced)).foregroundStyle(
            Palette.muted
          ).textSelection(.enabled)
          if !project.aliases.isEmpty {
            Text("A voce: " + project.aliases.joined(separator: ", ")).font(.system(size: 12))
              .foregroundStyle(Palette.muted)
          }
          HStack {
            Text(
              "\(project.agent.rawValue.capitalized) · \(controller.settings.fullAccess ? "Accesso completo (globale)" : project.access.title)"
            ).font(
              .system(size: 11))
            Spacer()
            Button("Apri cartella") { NSWorkspace.shared.open(project.url) }
          }
        }
      }
    }.sheet(item: $editing) { project in ProjectEditor(controller: controller, initial: project) }
  }
}
struct ProjectEditor: View {
  @Bindable var controller: OrbitController
  let initial: Workspace
  @Environment(\.dismiss) private var dismiss
  @State private var project: Workspace
  @State private var aliases: String
  @State private var warning = ""
  init(controller: OrbitController, initial: Workspace) {
    self.controller = controller
    self.initial = initial
    _project = State(initialValue: initial)
    _aliases = State(initialValue: initial.aliases.joined(separator: ", "))
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("Il tuo progetto").font(.system(size: 23, weight: .bold, design: .rounded))
      TextField("Nome", text: $project.name).textFieldStyle(.roundedBorder)
      DirectoryField(title: "Cartella", value: $project.directory)
      TextField("Soprannomi, separati da virgole", text: $aliases).textFieldStyle(.roundedBorder)
      ControlRow("Agente predefinito") {
        Picker("Agente", selection: $project.agent) {
          ForEach(Agent.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
        }.frame(width: 160)
      }
      ControlRow("Permessi") {
        Picker("Permessi", selection: $project.access) {
          ForEach(Access.allCases, id: \.self) { Text($0.title).tag($0) }
        }.frame(width: 160)
      }
      Text(
        project.access == .full
          ? "L’accesso completo consente all’agente di eseguire comandi fuori dalla cartella del progetto senza richieste di approvazione del CLI."
          : "I permessi dipendono dalla sandbox e dalle regole del CLI selezionato. Se un’azione è bloccata, puoi proseguire nel terminale."
      ).font(.system(size: 11)).foregroundStyle(project.access == .full ? .orange : Palette.muted)
      if !warning.isEmpty { Text(warning).foregroundStyle(.orange).font(.system(size: 12)) }
      HStack {
        Button("Annulla") { dismiss() }
        Spacer()
        Button("Salva") { save() }.buttonStyle(.borderedProminent)
      }
    }.padding(28).frame(width: 520).background(Palette.background).foregroundStyle(.white).tint(
      Palette.accent
    ).preferredColorScheme(.dark)
  }
  func save() {
    project.name = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
    var folder: ObjCBool = false
    guard !project.name.isEmpty,
      FileManager.default.fileExists(atPath: project.url.path, isDirectory: &folder),
      folder.boolValue
    else {
      warning = "Inserisci un nome e una cartella esistente."
      return
    }
    project.directory = project.url.standardizedFileURL.path
    guard
      !controller.snapshot.workspaces.contains(where: {
        $0.id != project.id
          && URL(fileURLWithPath: $0.directory).standardizedFileURL
            == project.url.standardizedFileURL
      })
    else {
      warning = "Questa cartella è già tra i progetti."
      return
    }
    project.aliases = aliases.split(separator: ",").map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }.filter { !$0.isEmpty }
    if let index = controller.snapshot.workspaces.firstIndex(where: { $0.id == project.id }) {
      controller.snapshot.workspaces[index] = project
    } else {
      controller.snapshot.workspaces.append(project)
    }
    dismiss()
  }
}
struct ModelsView: View {
  @Bindable var controller: OrbitController
  var body: some View {
    VStack(spacing: 20) {
      Card("Permessi dell’agente") {
        ControlRow("Accesso completo") {
          Toggle("Accesso completo", isOn: controller.binding(\.fullAccess)).toggleStyle(.switch)
        }
        Text(
          controller.settings.fullAccess
            ? "Orbit può eseguire comandi, modificare file anche fuori dai progetti e usare la rete senza conferme di esecuzione. Computer Use può accedere alle app richieste."
            : "Ogni progetto usa i propri permessi. Le richieste generali possono modificare solo la cartella di lavoro e chiedono conferma quando serve."
        )
        .font(.system(size: 12)).foregroundStyle(Palette.muted)
        Text(
          "Si applica alle nuove sessioni e ai turni ripresi, anche senza progetto. I turni già in corso mantengono i loro permessi. Disattivandolo, i nuovi turni tornano ai permessi del progetto."
        )
        .font(.system(size: 11)).foregroundStyle(Palette.muted)
        Text(
          "Le domande, i login e le altre autorizzazioni richieste dagli MCP restano disponibili nel pannello Sessioni."
        )
        .font(.system(size: 11)).foregroundStyle(Palette.muted)
      }
      Card("Interprete delle richieste") {
        ControlRow("Agente") {
          Picker("Interprete", selection: controller.binding(\.interpreter)) {
            ForEach(Agent.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
          }.frame(width: 170)
        }
        Text(
          "L’interprete sceglie progetto e sessione. Non modifica i file e non eredita strumenti o MCP dalle impostazioni del CLI."
        ).font(.system(size: 12)).foregroundStyle(Palette.muted)
      }
      if controller.settings.interpreter == .codex {
        ModelCard(
          title: "Modello per l’interprete", choice: controller.binding(\.assistant),
          controller: controller)
      }
      ModelCard(
        title: "Modello per i lavori Codex", choice: controller.binding(\.worker),
        controller: controller)
      Card("Integrazioni Codex") {
        Text(
          "Orbit usa la configurazione e l’account del tuo CLI Codex. MCP, skill e plugin disponibili al CLI possono essere usati nei lavori; gli strumenti esclusivi dell’app Codex richiedono un collegamento separato."
        )
        .font(.system(size: 12)).foregroundStyle(Palette.muted)
        HStack {
          Text("MCP per i nuovi lavori nella cartella generale").font(.system(size: 12))
          Spacer()
          if controller.catalogLoading { ProgressView().controlSize(.small) }
          Button("Verifica connessioni") { controller.refreshIntegrations() }.disabled(
            controller.catalogLoading)
        }
        if let error = controller.catalogError {
          Text(error).font(.system(size: 12)).foregroundStyle(.orange)
        }
        if controller.catalogLoaded {
          if controller.catalog.isEmpty {
            Text(
              controller.settings.worker.provider.local && !controller.settings.worker.integrations
                ? "Le integrazioni del CLI sono disabilitate per il modello locale."
                : "Nessun MCP disponibile in questa configurazione. Aggiungilo nel CLI Codex, poi verifica di nuovo."
            )
            .font(.system(size: 12)).foregroundStyle(Palette.muted)
          } else {
            IntegrationsList(items: controller.catalog)
          }
        }
        Text(
          "Le autorizzazioni e le domande compaiono in Sessioni. Puoi approvare una richiesta alla volta, rifiutarla o fermare il lavoro. Il browser Orbit viene collegato separatamente a ogni sessione."
        )
        .font(.system(size: 11)).foregroundStyle(Palette.muted)
      }
      Card("Navigazione web") {
        ControlRow("Browser per i lavori Codex") {
          Toggle("Browser", isOn: controller.binding(\.browserEnabled))
            .disabled(!BrowserSupport.ready(in: controller.disk.folder))
        }
        Text(
          "Orbit può aprire siti, leggere pagine e navigare in una finestra Chrome dedicata. Ogni sessione conserva il proprio profilo. Puoi effettuare il login direttamente nella finestra e poi continuare la sessione."
        )
        .font(.system(size: 12)).foregroundStyle(Palette.muted)
        HStack {
          Label(
            BrowserSupport.ready(in: controller.disk.folder)
              ? "Browser configurato" : "Configurazione necessaria",
            systemImage: BrowserSupport.ready(in: controller.disk.folder)
              ? "checkmark.circle" : "globe")
          Spacer()
          if controller.browserInstalling { ProgressView().controlSize(.small) }
          Button(
            BrowserSupport.ready(in: controller.disk.folder)
              ? "Reinstalla strumenti" : "Configura browser"
          ) {
            controller.installBrowser()
          }.disabled(controller.browserInstalling)
        }
        Text(
          "Richiede Node.js 18 o successivo e Google Chrome. Gli strumenti Playwright MCP vengono installati nella cartella dati di Orbit."
        )
        .font(.system(size: 11)).foregroundStyle(Palette.muted)
      }
      Card("CLI e account") {
        ForEach(Agent.allCases, id: \.self) { agent in
          VStack(alignment: .leading, spacing: 9) {
            HStack {
              Text(agent.rawValue.capitalized).fontWeight(.semibold)
              Spacer()
              Image(
                systemName: Executables.locate(
                  agent,
                  override: agent == .codex
                    ? controller.settings.codexExecutable : controller.settings.claudeExecutable)
                  == nil ? "xmark.circle" : "checkmark.circle"
              ).foregroundStyle(Palette.accent)
            }
            HStack {
              TextField(
                "Percorso automatico",
                text: controller.binding(agent == .codex ? \.codexExecutable : \.claudeExecutable)
              ).textFieldStyle(.roundedBorder)
              Button("Scegli…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = false
                panel.canChooseFiles = true
                if panel.runModal() == .OK, let path = panel.url?.path {
                  if agent == .codex {
                    controller.settings.codexExecutable = path
                  } else {
                    controller.settings.claudeExecutable = path
                  }
                }
              }
            }
            HStack {
              Button("Login nel terminale") { controller.login(agent) }
              Button("Documentazione") {
                NSWorkspace.shared.open(
                  URL(
                    string: agent == .codex
                      ? "https://developers.openai.com/codex/cli/"
                      : "https://code.claude.com/docs/en/overview")!)
              }
            }.controlSize(.small)
          }
          if agent == .codex { Divider() }
        }
        Text(
          "Orbit usa l’autenticazione già salvata dai CLI. I lavori partono come processi del CLI: non aprono automaticamente una chat nella finestra dell’app Codex. Claude usa il proprio account e modello."
        ).font(.system(size: 11)).foregroundStyle(Palette.muted)
      }
    }
  }
}
struct ModelCard: View {
  let title: String
  @Binding var choice: ModelChoice
  @Bindable var controller: OrbitController
  @State private var models: [String] = []
  @State private var busy = false
  @State private var note = ""
  var body: some View {
    Card(title) {
      ControlRow("Provider") {
        Picker("Provider", selection: $choice.provider) {
          ForEach(Provider.allCases, id: \.self) { Text($0.title).tag($0) }
        }.frame(width: 220)
      }
      HStack {
        TextField(
          choice.provider.local ? "Nome esatto del modello locale" : "Modello predefinito del CLI",
          text: $choice.model
        ).textFieldStyle(.roundedBorder)
        if choice.provider.local {
          Button(busy ? "Caricamento…" : "Aggiorna") { refresh() }.disabled(busy)
        }
      }
      if !models.isEmpty {
        Picker("Modelli disponibili", selection: $choice.model) {
          Text("Scegli un modello").tag("")
          ForEach(models, id: \.self) { Text($0).tag($0) }
          if !choice.model.isEmpty && !models.contains(choice.model) {
            Text(choice.model).tag(choice.model)
          }
        }
      }
      if choice.provider.local {
        HStack {
          Text(choice.provider == .ollama ? "Server: 127.0.0.1:11434" : "Server: 127.0.0.1:1234")
            .font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.muted)
          Spacer()
          Button("Apri \(choice.provider == .ollama ? "Ollama" : "LM Studio")") {
            let app = URL(
              fileURLWithPath: choice.provider == .ollama
                ? "/Applications/Ollama.app" : "/Applications/LM Studio.app")
            if FileManager.default.fileExists(atPath: app.path) {
              NSWorkspace.shared.open(app)
            } else {
              NSWorkspace.shared.open(
                URL(
                  string: choice.provider == .ollama
                    ? "https://ollama.com/download" : "https://lmstudio.ai/download")!)
            }
          }
        }
        Toggle("Usa anche le integrazioni del CLI nei lavori", isOn: $choice.integrations)
          .toggleStyle(.switch)
        Text(
          "Scarica prima un modello compatibile con Codex nel provider scelto e avvia il suo server. Orbit non scarica modelli. L’interprete resta isolato anche con questa opzione."
        ).font(.system(size: 11)).foregroundStyle(Palette.muted)
      }
      if !note.isEmpty { Text(note).font(.system(size: 11)).foregroundStyle(.orange) }
    }.onChange(of: choice.provider) { _, _ in
      models = []
      choice.model = ""
      note = ""
      if choice.provider.local { refresh() }
    }
  }
  func refresh() {
    busy = true
    note = ""
    let provider = choice.provider
    Task {
      do {
        let list = try await LocalModels.list(provider)
        if choice.provider == provider {
          models = list
          note = list.isEmpty ? "Nessun modello installato nel provider." : ""
        }
      } catch { if choice.provider == provider { note = error.localizedDescription } }
      busy = false
    }
  }
}
struct VoiceSettingsView: View {
  @Bindable var controller: OrbitController
  @State private var key = ""
  @State private var systemVoices: [AVSpeechSynthesisVoice] = []
  @State private var allLanguages = false
  @State private var query = ""
  @State private var voices: [Voice] = []
  @State private var busy = false
  @State private var page = 1
  @State private var more = false
  @State private var note = ""
  var body: some View {
    VStack(spacing: 20) {
      Card("Voce di Orbit") {
        ControlRow("Servizio vocale") {
          Picker("Servizio vocale", selection: controller.binding(\.speechProvider)) {
            ForEach(SpeechProvider.allCases, id: \.self) { Text($0.title).tag($0) }
          }.frame(width: 230)
        }
        Text(
          controller.settings.speechProvider == .system
            ? "Orbit parla con una voce Apple sul Mac. Non usa Fish Audio per leggere le risposte."
            : "Orbit usa la voce Fish selezionata. Senza una chiave API usa la voce Apple configurata qui sotto."
        )
        .font(.system(size: 12)).foregroundStyle(Palette.muted)
      }
      if controller.settings.speechProvider == .system {
        systemVoiceCard
      } else {
        Card("Fish Audio") {
          HStack {
            SecureField("Chiave API Fish Audio", text: $key).textFieldStyle(.roundedBorder)
            Button("Salva") {
              do {
                try controller.disk.setCredential(key)
                note = "Chiave salvata sul Mac."
              } catch { note = error.localizedDescription }
            }
          }
          Text(
            "Senza chiave puoi usare la voce di sistema. La chiave resta nella cartella privata Orbit e non viene condivisa con gli agenti."
          ).font(.system(size: 11)).foregroundStyle(Palette.muted)
          HStack {
            TextField("Cerca una voce o incolla il link Fish Audio", text: $query).textFieldStyle(
              .roundedBorder
            ).onSubmit { search(reset: true) }
            Button(busy ? "Ricerca…" : "Cerca") { search(reset: true) }.disabled(
              busy || key.isEmpty)
          }
          ForEach(voices) { voice in
            HStack {
              VStack(alignment: .leading, spacing: 3) {
                Text(voice.title).fontWeight(.semibold)
                Text(voice.author).font(.system(size: 11)).foregroundStyle(Palette.muted)
              }
              Spacer()
              Button(controller.settings.fishVoiceID == voice.id ? "Selezionata" : "Usa voce") {
                controller.settings.fishVoiceID = voice.id
                controller.settings.fishVoiceTitle = voice.title
              }.disabled(controller.settings.fishVoiceID == voice.id)
            }
          }
          if more { Button("Altre voci") { search(reset: false) }.disabled(busy) }
          if !note.isEmpty {
            Text(note).font(.system(size: 11)).foregroundStyle(Palette.muted).textSelection(
              .enabled)
          }
          Divider()
          ControlRow("Voce selezionata") {
            Text(controller.settings.fishVoiceTitle).fontWeight(.semibold)
          }
          Text(controller.settings.fishVoiceID).font(.system(size: 10, design: .monospaced))
            .foregroundStyle(Palette.muted).textSelection(.enabled)
          ControlRow("Modello vocale") {
            Picker("Modello", selection: controller.binding(\.fishModel)) {
              Text("Automatico").tag("auto")
              Text("S2.1 Pro · gratuito").tag("s2.1-pro-free")
              Text("S2.1 Pro").tag("s2.1-pro")
              Text("S2 Pro").tag("s2-pro")
              Text("S1").tag("s1")
              Text("Drama 3 · preview").tag("drama-3-preview")
            }.frame(width: 200)
          }
          Text(
            "Automatico prova S2.1 Pro e passa al tier gratuito se Fish risponde con credito insufficiente. L’uso dei modelli a pagamento può consumare credito Fish Audio."
          ).font(.system(size: 11)).foregroundStyle(Palette.muted)
          ControlRow("Usa la voce di sistema se Fish non risponde") {
            Toggle("Fallback", isOn: controller.binding(\.systemFallback)).toggleStyle(.switch)
          }
          HStack {
            Spacer()
            Link(
              "Apri Fish Audio",
              destination: URL(
                string:
                  "https://fish.audio/app/text-to-speech/?modelId=\(controller.settings.fishVoiceID)"
              )!
            )
          }
        }
        if controller.settings.systemFallback || key.isEmpty { systemVoiceCard }
      }
      Card("Ascolta un’anteprima") {
        ControlRow("Velocità") {
          Slider(value: controller.binding(\.speechSpeed), in: 0.5...2).frame(width: 200)
          Text(
            controller.settings.speechSpeed.formatted(.number.precision(.fractionLength(1))) + "×"
          )
          .font(.system(size: 11)).monospacedDigit()
        }
        HStack {
          Button {
            controller.speak("Ciao! Sono Orbit. Dimmi su quale progetto vuoi lavorare.")
          } label: {
            Label("Prova la voce", systemImage: "play.fill")
          }
          Button("Ferma") { controller.audio?.stopSpeaking() }
        }
      }
    }.onAppear {
      key = controller.disk.credential() ?? ""
      refreshSystemVoices()
    }.onChange(of: allLanguages) { _, _ in refreshSystemVoices() }
      .onChange(of: controller.settings.language) { _, _ in refreshSystemVoices() }
      .onChange(of: controller.settings.speechProvider) { _, _ in controller.audio?.stopSpeaking() }
      .onChange(of: controller.settings.systemVoiceID) { _, _ in controller.audio?.stopSpeaking() }
  }
  var systemVoiceCard: some View {
    Card(controller.settings.speechProvider == .system ? "Voci Apple" : "Voce Apple di riserva") {
      ControlRow("Voce") {
        Picker("Voce Apple", selection: controller.binding(\.systemVoiceID)) {
          Text("Automatica · \(controller.settings.language)").tag("")
          if !controller.settings.systemVoiceID.isEmpty,
            !systemVoices.contains(where: { $0.identifier == controller.settings.systemVoiceID })
          {
            Text(
              SystemVoices.selected(controller.settings.systemVoiceID)
                .map(SystemVoices.title) ?? "Voce salvata non disponibile"
            )
            .tag(controller.settings.systemVoiceID)
          }
          ForEach(systemVoices, id: \.identifier) {
            Text(SystemVoices.title($0)).tag($0.identifier)
          }
        }.frame(maxWidth: 340)
      }
      Toggle("Mostra tutte le lingue", isOn: $allLanguages).toggleStyle(.switch)
      if systemVoices.isEmpty {
        Text(
          "Nessuna voce disponibile per questa lingua. Aggiungi una voce nelle impostazioni macOS e premi Aggiorna."
        )
        .font(.system(size: 12)).foregroundStyle(Palette.muted)
      }
      if !controller.settings.systemVoiceID.isEmpty,
        SystemVoices.selected(controller.settings.systemVoiceID) == nil
      {
        Text(
          "La voce salvata non è più disponibile. Orbit usa la voce automatica finché non ne scegli un’altra."
        )
        .font(.system(size: 12)).foregroundStyle(.orange)
      }
      Text(
        systemVoices.contains(where: SystemVoices.isSiri)
          ? "Le voci Siri disponibili su questo Mac sono indicate nell’elenco."
          : "macOS non espone attualmente voci Siri a Orbit per le lingue mostrate. Le voci di Siri possono essere diverse da quelle disponibili alle app."
      )
      .font(.system(size: 12)).foregroundStyle(Palette.muted)
      HStack {
        Button("Aggiorna voci") { refreshSystemVoices() }
        Button("Gestisci voci macOS") {
          NSWorkspace.shared.open(
            URL(
              string: "x-apple.systempreferences:com.apple.preference.universalaccess?SpokenContent"
            )!)
        }
        Link(
          "Come aggiungere voci",
          destination: URL(string: "https://support.apple.com/it-it/guide/mac-help/mchlp2290/mac")!)
      }
      Text(
        "Puoi aggiungere voci da Impostazioni di Sistema → Accessibilità → Lettura e voce (Contenuto letto ad alta voce nelle versioni precedenti)."
      )
      .font(.system(size: 11)).foregroundStyle(Palette.muted)
    }
  }
  func refreshSystemVoices() {
    systemVoices =
      allLanguages
      ? AVSpeechSynthesisVoice.speechVoices().sorted {
        SystemVoices.title($0).localizedStandardCompare(SystemVoices.title($1)) == .orderedAscending
      } : SystemVoices.available(language: controller.settings.language)
  }
  func search(reset: Bool) {
    if reset {
      page = 1
      voices = []
    } else {
      page += 1
    }
    busy = true
    note = ""
    let query = query
    let page = page
    let client = FishClient(token: key)
    Task {
      do {
        let result = try await client.voices(query, page: page)
        voices += result.items
        more = result.more
        if voices.isEmpty { note = "Nessuna voce trovata. Prova il link diretto della voce." }
      } catch { note = error.localizedDescription }
      busy = false
    }
  }
}
struct MemoryView: View {
  @Bindable var controller: OrbitController
  @State private var newMemory = ""
  var body: some View {
    VStack(spacing: 20) {
      Card("Preferenze") {
        Text(
          "Puoi dire «Orbit, ricordati che…». Le preferenze vengono incluse nelle nuove richieste agli agenti."
        ).font(.system(size: 12)).foregroundStyle(Palette.muted)
        HStack {
          TextField("Aggiungi una preferenza", text: $newMemory).textFieldStyle(.roundedBorder)
            .onSubmit(add)
          Button("Aggiungi", action: add).disabled(
            newMemory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        ForEach(Array(controller.snapshot.memories.enumerated()), id: \.offset) { index, text in
          HStack(alignment: .top) {
            Text(text).font(.system(size: 13)).textSelection(.enabled)
            Spacer()
            Button {
              controller.snapshot.memories.remove(at: index)
            } label: {
              Image(systemName: "trash")
            }.buttonStyle(.plain)
          }
        }
      }
      Card("Conversazione recente") {
        HStack {
          Text("Le ultime richieste aiutano Orbit a capire le precisazioni.").font(
            .system(size: 12)
          ).foregroundStyle(Palette.muted)
          Spacer()
          Button("Cancella") { controller.snapshot.conversation = [] }
        }
        ForEach(
          Array(controller.snapshot.conversation.suffix(12).reversed().enumerated()), id: \.offset
        ) { _, exchange in
          VStack(alignment: .leading, spacing: 6) {
            Text(exchange.heard).fontWeight(.semibold)
            Text(exchange.reply).foregroundStyle(Palette.muted)
            Text(exchange.date.formatted(date: .abbreviated, time: .shortened)).font(
              .system(size: 10)
            ).foregroundStyle(Palette.muted)
          }.font(.system(size: 12))
          Divider()
        }
      }
    }
  }
  func add() {
    let text = newMemory.trimmingCharacters(in: .whitespacesAndNewlines)
    if !text.isEmpty {
      controller.snapshot.memories.append(text)
      newMemory = ""
    }
  }
}
extension OrbitController {
  func login(_ agent: Agent) {
    guard
      let executable = Executables.locate(
        agent, override: agent == .codex ? settings.codexExecutable : settings.claudeExecutable)
    else {
      error = AgentError.missing(agent).localizedDescription
      return
    }
    let quoted = "'" + executable.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    let file = disk.folder.appendingPathComponent("login-\(agent.rawValue).command")
    do {
      try Data("#!/bin/zsh\n\(quoted) \(agent == .codex ? "login" : "auth login")\n".utf8).write(
        to: file)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
      NSWorkspace.shared.open(file)
    } catch { self.error = error.localizedDescription }
  }
}
