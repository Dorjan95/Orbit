import AppKit
import OrbitCore
import ServiceManagement
import SwiftUI

@MainActor enum Palette {
  static let accent = Color(red: 0.76, green: 1, blue: 0.25)
  static let background = Color(red: 0.033, green: 0.043, blue: 0.047)
  static let card = Color(red: 0.065, green: 0.075, blue: 0.08)
  static let muted = Color.white.opacity(0.58)
}
extension OrbitController {
  func binding<T>(_ key: WritableKeyPath<OrbitCore.Settings, T>) -> Binding<T> {
    Binding(
      get: { self.settings[keyPath: key] },
      set: { value in
        var settings = self.settings
        settings[keyPath: key] = value
        self.settings = settings
      })
  }
}
struct Card<Content: View>: View {
  let title: String?
  @ViewBuilder let content: () -> Content
  init(_ title: String? = nil, @ViewBuilder content: @escaping () -> Content) {
    self.title = title
    self.content = content
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      if let title { Text(title).font(.system(size: 15, weight: .bold)).foregroundStyle(.white) }
      content()
    }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(
      Palette.card, in: RoundedRectangle(cornerRadius: 17))
  }
}
struct ControlRow<Content: View>: View {
  let title: String
  @ViewBuilder let content: () -> Content
  init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
    self.title = title
    self.content = content
  }
  var body: some View {
    HStack(spacing: 18) {
      Text(title).foregroundStyle(.white)
      Spacer(minLength: 10)
      content().labelsHidden()
    }.frame(minHeight: 30)
  }
}
struct OrbitSettingsView: View {
  @Bindable var controller: OrbitController
  @State private var typed = ""
  var body: some View {
    HStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 22) {
        HStack(spacing: 12) {
          Image(systemName: "waveform").font(.system(size: 29)).foregroundStyle(Palette.accent)
          VStack(alignment: .leading, spacing: 3) {
            Text("ORBIT").font(.system(size: 24, weight: .black, design: .rounded))
            Text("IL TUO ASSISTENTE").font(.system(size: 9, weight: .bold)).tracking(1.6)
              .foregroundStyle(Palette.muted)
          }
        }.padding(.top, 35).padding(.bottom, 14)
        ForEach(Section.allCases) { section in
          Button {
            controller.section = section
          } label: {
            HStack(spacing: 13) {
              Image(systemName: section.symbol).frame(width: 20)
              Text(section.rawValue).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                .minimumScaleFactor(0.9)
              Spacer()
              if controller.section == section {
                Rectangle().fill(Palette.accent).frame(width: 5, height: 5)
              }
            }
            .foregroundStyle(controller.section == section ? .white : Palette.muted).padding(
              .horizontal, 15
            ).frame(height: 43).background(
              controller.section == section ? Color.white.opacity(0.06) : .clear,
              in: RoundedRectangle(cornerRadius: 12))
          }.buttonStyle(.plain)
        }
        Spacer()
        HStack(spacing: 8) {
          Rectangle().fill(Palette.accent).frame(width: 6, height: 6)
          Text(controller.isListening ? "TI STO ASCOLTANDO" : "PRONTO SUL TUO MAC").font(
            .system(size: 9, weight: .bold)
          ).tracking(1.3)
        }
        Text("Voce → progetto\n→ risultato").font(.system(size: 11, design: .monospaced))
          .foregroundStyle(Palette.muted)
      }.padding(22).frame(width: 220).frame(maxHeight: .infinity).background(.black.opacity(0.15))
      Rectangle().fill(.white.opacity(0.09)).frame(width: 1)
      VStack(alignment: .leading, spacing: 22) {
        HStack {
          VStack(alignment: .leading, spacing: 7) {
            Text(controller.section.rawValue.uppercased()).font(
              .system(size: 27, weight: .black, design: .rounded)
            ).tracking(1)
            Text(controller.section.subtitle).font(.system(size: 14)).foregroundStyle(Palette.muted)
          }
          Spacer()
          Button {
            controller.beginListening()
          } label: {
            Image(systemName: controller.isListening ? "mic.fill" : "mic").font(.system(size: 20))
              .foregroundStyle(Palette.accent).padding(13).background(Palette.card, in: Circle())
          }.buttonStyle(.plain).help("Parla con Orbit")
        }
        if !controller.settings.configured { SetupCard(controller: controller) }
        if let notice = controller.migrationNotice {
          HStack {
            Text(notice).font(.system(size: 12))
            Spacer()
            Button("OK") { controller.migrationNotice = nil }
          }.padding(12).background(
            Palette.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        }
        if let error = controller.error {
          HStack(alignment: .top) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            Text(error).font(.system(size: 12)).textSelection(.enabled)
            Spacer()
            Button {
              controller.error = nil
            } label: {
              Image(systemName: "xmark")
            }.buttonStyle(.plain)
          }.padding(12).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
        ScrollView {
          Group {
            switch controller.section {
            case .general: GeneralView(controller: controller)
            case .sessions: SessionsView(controller: controller)
            case .mascot: MascotSettingsView(controller: controller)
            case .models: ModelsView(controller: controller)
            case .voice: VoiceSettingsView(controller: controller)
            case .projects: ProjectsView(controller: controller)
            case .memory: MemoryView(controller: controller)
            }
          }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 12)
        }.scrollIndicators(.hidden)
        HStack(spacing: 12) {
          TextField("Scrivi una richiesta a Orbit…", text: $typed).textFieldStyle(.plain).onSubmit(
            send)
          if controller.isInterpreting {
            ProgressView().controlSize(.small)
            Button("Ferma") { controller.cancelListening() }
          } else {
            Button(action: send) {
              Image(systemName: "arrow.up.circle.fill").font(.system(size: 24)).foregroundStyle(
                typed.isEmpty ? Palette.muted : Palette.accent)
            }.buttonStyle(.plain).disabled(
              typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }
        }.padding(13).background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
      }.padding(28).padding(.top, 16)
    }.frame(minWidth: 860, minHeight: 680).background(Palette.background).foregroundStyle(.white)
      .tint(Palette.accent).preferredColorScheme(.dark)
  }
  func send() {
    let request = typed
    typed = ""
    controller.submit(request)
  }
}
struct SetupCard: View {
  @Bindable var controller: OrbitController
  var body: some View {
    Card {
      HStack(alignment: .top) {
        Image(systemName: "sparkles").foregroundStyle(Palette.accent)
        VStack(alignment: .leading, spacing: 6) {
          Text("Benvenuto in Orbit").fontWeight(.bold)
          Text(
            "Attiva microfono e riconoscimento vocale. Poi aggiungi un progetto e usa «hey Orbit» oppure la scorciatoia."
          ).font(.system(size: 12)).foregroundStyle(Palette.muted)
        }
        Spacer()
        Button("Attiva la voce") { Task { await controller.audio?.permissions() } }.buttonStyle(
          .borderedProminent)
      }
      HStack {
        Label(
          Executables.locate(.codex, override: controller.settings.codexExecutable) == nil
            ? "Codex CLI da installare" : "Codex CLI disponibile", systemImage: "terminal")
        Spacer()
        Button("Configura senza voce") { controller.settings.configured = true }
      }.font(.system(size: 11)).foregroundStyle(Palette.muted)
    }
  }
}
struct GeneralView: View {
  @Bindable var controller: OrbitController
  var body: some View {
    VStack(spacing: 20) {
      Card("Scorciatoie") {
        ControlRow("Tieni premuto per parlare") {
          ShortcutRecorder(
            key: controller.binding(\.pushKey), modifiers: controller.binding(\.pushModifiers))
        }
        Divider()
        ControlRow("Mostra o nascondi le sessioni") {
          ShortcutRecorder(
            key: controller.binding(\.sessionsKey),
            modifiers: controller.binding(\.sessionsModifiers))
        }
        Text("Esc interrompe l’ascolto o l’interpretazione. Le sessioni continuano in background.")
          .font(.system(size: 11)).foregroundStyle(Palette.muted)
      }
      Card("Lingua") {
        ControlRow("Lingua di dettatura") {
          Picker("Lingua", selection: controller.binding(\.language)) {
            Text("Italiano").tag("it-IT")
            Text("English").tag("en-US")
            Text("Español").tag("es-ES")
            Text("Français").tag("fr-FR")
            Text("Deutsch").tag("de-DE")
          }.frame(width: 145)
        }
        Text("Orbit usa il riconoscimento sul dispositivo quando disponibile per la lingua scelta.")
          .font(.system(size: 11)).foregroundStyle(Palette.muted)
      }
      Card("Comportamento") {
        ControlRow("Apri all’avvio del Mac") {
          Toggle(
            "Avvio",
            isOn: Binding(
              get: {
                SMAppService.mainApp.status == .enabled
                  || SMAppService.mainApp.status == .requiresApproval
              },
              set: { value in
                do {
                  if value {
                    try SMAppService.mainApp.register()
                  } else {
                    try SMAppService.mainApp.unregister()
                  }
                  controller.settings.startup = value
                } catch { controller.error = error.localizedDescription }
              }))
        }
        Divider()
        ControlRow("Si attiva quando dici «hey Orbit»") {
          Toggle("Ascolto", isOn: controller.binding(\.handsFree))
        }
        ControlRow("Anche battendo due volte le mani") {
          Toggle("Battito", isOn: controller.binding(\.claps)).disabled(
            !controller.settings.handsFree)
        }
        Text(
          "Il rilevamento del battito è sperimentale e dipende dal microfono e dal rumore ambientale."
        ).font(.system(size: 11)).foregroundStyle(Palette.muted)
        ControlRow("Interrompi la voce dicendo «hey Orbit»") {
          Toggle("Interruzione", isOn: controller.binding(\.interruption))
        }
        Divider()
        ControlRow("Mostra sempre la barra flottante") {
          Toggle("Barra", isOn: controller.binding(\.alwaysShowVoice))
        }
        ControlRow("Opacità del pannello") {
          Slider(value: controller.binding(\.panelOpacity), in: 0.5...1).frame(width: 220)
        }
        ControlRow("Suono all’inizio dell’ascolto") {
          Toggle("Suono", isOn: controller.binding(\.sound))
        }
        ControlRow("Annuncia l’avvio e le risposte dei lavori") {
          Toggle("Annunci", isOn: controller.binding(\.announcements))
        }
        ControlRow("Leggi il risultato della sessione") {
          Toggle("Risultati", isOn: controller.binding(\.summaries))
        }
        ControlRow("Apri il primo link del risultato") {
          Toggle("Link", isOn: controller.binding(\.openResults))
        }
        Divider()
        ControlRow("Sessioni simultanee") {
          Stepper(
            "\(controller.settings.maximumJobs)", value: controller.binding(\.maximumJobs),
            in: 1...6
          ).labelsHidden()
          Text("\(controller.settings.maximumJobs)").monospacedDigit().frame(width: 18)
        }
        DirectoryField(
          title: "Richieste senza progetto", value: controller.binding(\.generalDirectory))
        DirectoryField(
          title: "Cartella per i nuovi progetti", value: controller.binding(\.newProjectsDirectory))
      }
    }.toggleStyle(.switch)
  }
}
struct ShortcutRecorder: View {
  @Binding var key: UInt32
  @Binding var modifiers: UInt32
  @State private var recording = false
  @State private var monitor: Any?
  var body: some View {
    Button(
      recording ? "Premi una combinazione…" : GlobalShortcuts.label(key: key, modifiers: modifiers)
    ) { start() }.buttonStyle(.bordered).onDisappear(perform: stop)
  }
  func start() {
    stop()
    recording = true
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      if event.keyCode == 53 {
        stop()
        return nil
      }
      let flags = GlobalShortcuts.carbon(event.modifierFlags)
      if flags != 0 {
        key = UInt32(event.keyCode)
        modifiers = flags
        stop()
      }
      return nil
    }
  }
  func stop() {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    recording = false
  }
}
struct DirectoryField: View {
  let title: String
  @Binding var value: String
  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(title).font(.system(size: 12)).foregroundStyle(Palette.muted)
      HStack {
        TextField("Scegli una cartella", text: $value).textFieldStyle(.roundedBorder)
        Button("Scegli…") {
          let panel = NSOpenPanel()
          panel.canChooseDirectories = true
          panel.canChooseFiles = false
          panel.canCreateDirectories = true
          if panel.runModal() == .OK, let url = panel.url { value = url.path }
        }
      }
    }
  }
}
struct SessionsView: View {
  @Bindable var controller: OrbitController
  var compact = false
  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack {
        Label("SESSIONI ATTIVE", systemImage: "bolt.fill").font(.system(size: 13, weight: .bold))
          .tracking(1).foregroundStyle(Palette.accent)
        Spacer()
        Text("\(controller.activeCount)").monospacedDigit().foregroundStyle(Palette.muted)
      }
      if controller.visibleJobs.filter({ $0.status.ongoing }).isEmpty {
        Card {
          Text("Nessuna sessione attiva").font(.system(size: 17, weight: .bold))
          Text(
            "Di’ «hey Orbit» e chiedi di lavorare su un progetto. Puoi anche scrivere una richiesta qui sotto."
          ).font(.system(size: 13)).foregroundStyle(Palette.muted)
        }
      }
      ForEach(controller.visibleJobs.filter { $0.status.ongoing }) { job in
        JobCard(controller: controller, job: job)
      }
      HStack {
        Label("CONCLUSE", systemImage: "clock").font(.system(size: 13, weight: .bold)).tracking(1)
        Spacer()
        Button("Pulisci") { controller.clearFinished() }.disabled(
          controller.visibleJobs.allSatisfy { $0.status.ongoing })
      }
      ForEach(controller.visibleJobs.filter { !$0.status.ongoing }) { job in
        JobCard(controller: controller, job: job)
      }
    }
  }
}
struct JobCard: View {
  @Bindable var controller: OrbitController
  let job: Job
  @State private var reply = ""
  @State private var expanded = false
  var body: some View {
    Card {
      HStack(spacing: 10) {
        Rectangle().fill(Palette.accent).frame(width: 6, height: 6)
        Text(job.workspaceName).font(.system(size: 17, weight: .bold))
        Image(systemName: job.agent == .codex ? "sparkles" : "asterisk").font(.system(size: 10))
        Spacer()
        Text(job.status.title).font(.system(size: 11, weight: .semibold)).padding(.horizontal, 10)
          .padding(.vertical, 5).background(color.opacity(0.13), in: Capsule()).foregroundStyle(
            color)
      }
      Text(job.request).font(.system(size: 12)).foregroundStyle(Palette.muted).lineLimit(
        expanded ? nil : 3)
      if job.status == .running {
        HStack {
          ProgressView().controlSize(.small)
          Text(job.activity).font(.system(size: 11)).lineLimit(2)
        }
      }
      if !job.result.isEmpty {
        Text(job.result).font(.system(size: 12)).textSelection(.enabled).lineLimit(
          expanded ? nil : 5
        ).frame(maxWidth: .infinity, alignment: .leading).padding(11).background(
          color.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        Button(expanded ? "Mostra meno" : "Leggi tutto") { expanded.toggle() }.buttonStyle(.plain)
          .font(.system(size: 11)).foregroundStyle(Palette.muted)
      }
      if !job.queued.isEmpty {
        Text("\(job.queued.count) richieste in coda per questa sessione").font(.system(size: 11))
          .foregroundStyle(Palette.accent)
      }
      HStack {
        TextField(
          job.status == .running ? "Aggiungi una richiesta alla coda…" : "Cosa deve fare adesso?",
          text: $reply
        ).textFieldStyle(.plain).onSubmit(send)
        Button(action: send) {
          Image(systemName: "arrow.up.circle.fill").font(.system(size: 20)).foregroundStyle(
            reply.isEmpty ? Palette.muted : Palette.accent)
        }.buttonStyle(.plain).disabled(
          reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }.padding(10).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
      HStack(spacing: 10) {
        Button {
          controller.openTerminal(job)
        } label: {
          Label("Terminale", systemImage: "terminal")
        }
        Button {
          controller.openLog(job)
        } label: {
          Label("Log", systemImage: "doc.text")
        }
        Button {
          controller.selectedSession = job.id
          controller.beginListening()
        } label: {
          Label("Rispondi", systemImage: "arrowshape.turn.up.left")
        }
        Spacer(minLength: 0)
        if job.status.ongoing {
          Button("Ferma") { controller.cancelJob(job.id) }
        } else {
          Button {
            controller.dismissJob(job.id)
          } label: {
            Image(systemName: "xmark")
          }.help("Nascondi la sessione")
        }
      }.buttonStyle(.bordered).controlSize(.small)
      Text(
        "\(job.agent.rawValue.capitalized) · \(job.model.provider.title) · \(job.created.formatted(date:.abbreviated,time:.shortened))"
      ).font(.system(size: 9)).foregroundStyle(Palette.muted)
    }.overlay(
      RoundedRectangle(cornerRadius: 17).stroke(
        controller.selectedSession == job.id ? Palette.accent.opacity(0.35) : .clear, lineWidth: 1)
    ).onTapGesture { controller.selectedSession = job.id }
  }
  var color: Color {
    job.status == .failed ? .orange : job.status == .cancelled ? Palette.muted : Palette.accent
  }
  func send() {
    controller.continueJob(job.id, prompt: reply)
    reply = ""
  }
}
