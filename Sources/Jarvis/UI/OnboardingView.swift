import SwiftUI
import AppKit
import AVFoundation
import Speech

/// §6 — six steps, each with a real check. 520 × 600.
struct OnboardingView: View {
    @Bindable var coordinator: Coordinator
    let onDone: () -> Void
    @State private var step = 0
    @State private var micOK = SpeechService.micStatus == .authorized
    @State private var speechOK = SpeechService.speechStatus == .authorized
    @State private var chordPressed = false
    @State private var chordReleased = false
    @State private var chordProbe: UInt32?
    @State private var claudeVersion: String?
    @State private var codexVersion: String?
    @State private var claudeLoggedIn: Bool?
    @State private var codexLoggedIn: Bool?
    @State private var checkingAgents = true
    @State private var fishKey = ""
    @State private var fishStatus = ""
    @State private var hasFish = Secrets.get(Secrets.fishKey) != nil
    @State private var projectURL: URL?
    @State private var projectName = ""
    @State private var projectAliases = ""
    @State private var projectAgent: AgentKind = .codex
    @State private var dropTargeted = false

    private let titles = ["Benvenuto", "Permessi", "Tieni premuto e parla", "Agenti", "Voce", "Primo progetto"]
    private let symbols = ["waveform", "lock.shield", "keyboard", "terminal", "speaker.wave.2", "folder"]

    var body: some View {
        VStack(spacing: 0) {
            dots.padding(.top, 28)
            Text("Passo \(step + 1) di \(titles.count) · \(titles[step])")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary)
                .padding(.top, 10)
                .contentTransition(.opacity)
            Spacer(minLength: 16)
            Group {
                switch step {
                case 0: welcome
                case 1: permissions
                case 2: chord
                case 3: agents
                case 4: voiceStep
                default: project
                }
            }
            .frame(maxWidth: 400)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .move(edge: .leading).combined(with: .opacity)))
            .id(step)
            Spacer()
            footer.padding(24)
        }
        .frame(width: 540, height: 640)
        .background(OrbitDesign.screen)
        .foregroundStyle(OrbitDesign.chalk).tint(OrbitDesign.lime).preferredColorScheme(.dark)
        .animation(Motion.spring, value: step)
        .onChange(of: step) { if step == 2 { startChordTest() } else { stopChordTest() } }
        .task(id: step) {
            guard step == 1 else { return }
            // Permissions can be granted by the hands-free startup request or in System Settings.
            // Refresh the rows rather than leaving the initial snapshot stuck on “Consenti”.
            while !Task.isCancelled {
                micOK = SpeechService.micStatus == .authorized
                speechOK = SpeechService.speechStatus == .authorized
                if micOK && speechOK { break }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        .onDisappear { stopChordTest() }
    }

    private var dots: some View {
        HStack(spacing: 8) {
            ForEach(0..<6) { i in
                Capsule().fill(i == step ? OrbitDesign.lime : Color.primary.opacity(0.15)).frame(width: i == step ? 20 : 6, height: 6)
            }
        }
    }

    private func title(_ t: String, _ sub: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbols[step])
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(OrbitDesign.lime)
                .frame(width: 52, height: 52)
                .background(OrbitDesign.lime.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.bottom, 6)
            Text(t).font(.system(size: 26, weight: .semibold)).tracking(-0.5)
            Text(sub).font(.system(size: 15)).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func check(_ ok: Bool?, _ label: String, detail: String? = nil, action: String? = nil, _ act: (() -> Void)? = nil) -> some View {
        HStack(spacing: 12) {
            Image(systemName: ok == true ? "checkmark.circle.fill" : (ok == nil ? "circle.dotted" : "circle"))
                .foregroundStyle(ok == true ? Color.green : Color.secondary).font(.system(size: 18))
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 15, weight: .medium))
                if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2) }
            }
            Spacer()
            if let action, let act, ok != true { Button(action, action: act).controlSize(.small) }
        }
        .padding(12)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        // The whole row reads as one option, so the whole row answers a click, not just the small button.
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { if ok != true { act?() } }
    }

    // MARK: steps

    private var welcome: some View {
        VStack(spacing: 24) {
            title("Orbit", "Di' cosa ti serve: Codex si mette al lavoro in background e Orbit ti aggiorna a voce.")
            Text("Usa il login Codex con ChatGPT che hai già. La voce di macOS è inclusa; Fish Audio è facoltativo.")
                .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .padding(12).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var permissions: some View {
        VStack(spacing: 16) {
            title("Permessi", "La voce resta su questo Mac. Per la scorciatoia non serve nessun permesso.")
            check(micOK, "Microfono", action: "Consenti") {
                AppLog.write("onboarding: mic tapped, status=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)")
                Task { micOK = await AVCaptureDevice.requestAccess(for: .audio); AppLog.write("onboarding: mic result=\(micOK)"); if !micOK { openPane("Privacy_Microphone") } }
            }
            check(speechOK, "Riconoscimento vocale", detail: "Dettatura sul Mac", action: "Consenti") {
                AppLog.write("onboarding: speech tapped, status=\(SpeechService.speechStatus.rawValue)")
                Task {
                    let ok = await SpeechService.requestSpeechAuthorization()
                    AppLog.write("onboarding: speech result=\(ok)")
                    speechOK = ok
                    if !ok { openPane("Privacy_SpeechRecognition") }
                }
            }
            if speechOK {
                let onDevice = SFSpeechRecognizer(locale: Locale(identifier: coordinator.settings.settings.speechLocale))?.supportsOnDeviceRecognition ?? false
                check(onDevice ? true : nil, coordinator.settings.settings.isItalian ? "Dettatura in italiano" : "Dettatura",
                      detail: onDevice ? "Il riconoscimento gira tutto sul Mac"
                                       : "Per ora passa dai server Apple. Scarica la lingua in Impostazioni › Tastiera › Dettatura per tenerla sul Mac.")
            }
        }
    }

    private var chord: some View {
        VStack(spacing: 16) {
            title("Tieni premuto e parla", "Tieni premuto \(coordinator.settings.settings.pushToTalk.display) adesso, poi rilascia.")
            check(chordPressed, "Pressione ricevuta")
            check(chordReleased, "Rilascio ricevuto")
            if coordinator.hotkeyError != nil || chordProbe == nil {
                VStack(spacing: 8) {
                    Text("Questa scorciatoia è già di un'altra app. Scegline un'altra:").font(.system(size: 12)).foregroundStyle(.secondary)
                    ShortcutRecorder(hotkey: Binding(get: { coordinator.settings.settings.pushToTalk }, set: { coordinator.settings.settings.pushToTalk = $0; startChordTest() }))
                }
            }
        }
    }

    private var agents: some View {
        VStack(spacing: 16) {
            title("Agenti", "Orbit guida le CLI che hai già installato.")
            check(claudeVersion != nil && claudeLoggedIn == true, "Claude Code (facoltativo)",
                  detail: checkingAgents ? "Controllo in corso…" : (claudeVersion.map { "\($0) · \(claudeLoggedIn == true ? "login fatto" : "login da fare")" } ?? "Non trovato"),
                  action: checkingAgents ? nil : (claudeVersion == nil ? "Installa" : "Fai il login")) {
                if claudeVersion == nil { NSWorkspace.shared.open(URL(string: "https://docs.anthropic.com/en/docs/claude-code")!) }
                else { coordinator.openTerminal(at: URL(fileURLWithPath: NSHomeDirectory()), command: "claude auth login") }
            }
            check(codexVersion != nil && (coordinator.settings.settings.assistantBackend.provider.isLocal || codexLoggedIn == true), "Codex",
                  detail: checkingAgents ? "Controllo in corso…" : (codexVersion.map { "\($0) · \(coordinator.settings.settings.assistantBackend.provider.isLocal ? "modello locale" : (codexLoggedIn == true ? "login fatto" : "login da fare"))" } ?? "Non trovato"),
                  action: checkingAgents ? nil : (codexVersion == nil ? "Installa" : (coordinator.settings.settings.assistantBackend.provider.isLocal ? nil : "Fai il login"))) {
                if codexVersion == nil { NSWorkspace.shared.open(URL(string: "https://github.com/openai/codex")!) }
                else { coordinator.openTerminal(at: URL(fileURLWithPath: NSHomeDirectory()), command: "codex login") }
            }
            Picker("Assistente vocale", selection: Binding(get: { coordinator.settings.settings.orchestratorAgent },
                                                          set: { coordinator.settings.settings.orchestratorAgent = $0 })) {
                ForEach(AgentKind.interpreterCases) { Text($0.displayName).tag($0) }
            }
            HStack {
                Button("Ricontrolla") { Task { await detectAgents() } }
                Button("Modelli locali…") { NSWorkspace.shared.open(URL(string: "orbit://settings?section=agents")!) }
            }.controlSize(.small)
        }
        .task { await detectAgents() }
    }

    private var voiceStep: some View {
        VStack(spacing: 16) {
            title("Voce", "Le risposte le legge Fish Audio. Senza chiave usa la voce di macOS.")
            if hasFish {
                check(true, "Chiave API salvata su questo Mac", detail: fishStatus.isEmpty ? nil : fishStatus)
                Button("Ascolta una prova") { coordinator.voice.speak(VoiceService.sample(coordinator.settings.settings)) }
            } else {
                SecureField("Chiave API di Fish Audio", text: $fishKey).textFieldStyle(.roundedBorder)
                Button("Salva e prova") {
                    Secrets.set(fishKey, for: Secrets.fishKey); hasFish = true; fishKey = ""
                    Task {
                        if let k = Secrets.get(Secrets.fishKey), let b = try? await FishAudio.balance(apiKey: k) { fishStatus = "Credito API $\(b.apiCreditUSD) · pacchetto \(b.balance.formatted())" }
                        coordinator.voice.speak(VoiceService.sample(coordinator.settings.settings))
                    }
                }.disabled(fishKey.isEmpty)
                Text("Salta questo passo per usare la voce di sistema.").font(.system(size: 12)).foregroundStyle(.tertiary)
            }
        }
    }

    private var project: some View {
        VStack(spacing: 16) {
            title("Primo progetto", "Trascina una cartella, dagli un nome e qualche soprannome da dire a voce.")
            VStack(spacing: 8) {
                Image(systemName: projectURL == nil ? "folder.badge.plus" : "folder.fill")
                    .font(.system(size: 20)).foregroundStyle(projectURL == nil ? Color.secondary : OrbitDesign.lime)
                Text(projectURL?.path ?? "Trascina qui una cartella")
                    .font(.system(size: 13)).foregroundStyle(projectURL == nil ? .secondary : .primary)
                    .lineLimit(1).truncationMode(.middle)
                Button(projectURL == nil ? "Scegli la cartella…" : "Cambia cartella…") { pickProjectFolder() }
                    .controlSize(.small)
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(dropTargeted ? OrbitDesign.lime.opacity(0.12) : Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(dropTargeted ? OrbitDesign.lime : Color.clear, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onTapGesture { pickProjectFolder() }
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                AppLog.write("onboarding: folder dropped (\(providers.count))")
                _ = providers.first?.loadObject(ofClass: URL.self) { u, _ in
                    Task { @MainActor in if let u { useProjectFolder(u) } }
                }
                return true
            }
            TextField("Nome", text: $projectName).textFieldStyle(.roundedBorder)
            TextField("Soprannomi, separati da virgola (es. il sito, la home)", text: $projectAliases).textFieldStyle(.roundedBorder)
            Picker("Agente predefinito", selection: $projectAgent) { ForEach(AgentKind.allCases) { Text($0.displayName).tag($0) } }.pickerStyle(.segmented)
            if !coordinator.registry.projects.isEmpty {
                Text("Tieni premuto \(coordinator.settings.settings.pushToTalk.display) e prova: «A che punto siamo?»").font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack {
            if step > 0 { Button("Indietro") { step -= 1 } }
            Spacer()
            if skippable { Button("Salta per ora") { advance() } }
            Button(step == 5 ? "Fine" : "Continua") {
                if step == 5, let u = projectURL, !projectName.isEmpty {
                    coordinator.registry.add(Project(name: projectName, path: u.path,
                                                     aliases: projectAliases.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                                                     defaultAgent: projectAgent,
                                                     permissionMode: coordinator.settings.settings.permissionMode(for: projectAgent)))
                }
                advance()
            }
            .buttonStyle(.borderedProminent).foregroundStyle(.black).disabled(!canContinue)
        }
    }

    private func pickProjectFolder() { FolderPicker.choose { useProjectFolder($0) } }

    /// Keeps a name the user already typed; only fills it in when the field is empty.
    private func useProjectFolder(_ u: URL) {
        projectURL = u
        if projectName.trimmingCharacters(in: .whitespaces).isEmpty { projectName = ProjectRegistry.suggestedName(for: u) }
    }

    private var skippable: Bool { step == 3 || step == 4 || step == 5 }
    private var canContinue: Bool {
        switch step {
        case 1: micOK && speechOK
        case 2: chordPressed && chordReleased
        case 3: coordinator.settings.settings.orchestratorAgent == .codex
            ? (coordinator.settings.settings.assistantBackend.provider.isLocal
               ? codexVersion != nil && coordinator.settings.settings.assistantBackend.configurationError == nil : codexLoggedIn == true)
            : claudeLoggedIn == true
        case 5: projectURL != nil && !projectName.isEmpty || !coordinator.registry.projects.isEmpty
        default: true
        }
    }

    private func advance() {
        if step == 5 { coordinator.settings.settings.onboardingComplete = true; onDone() } else { step += 1 }
    }

    private func openPane(_ anchor: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
    }

    private func startChordTest() {
        stopChordTest()
        chordPressed = false; chordReleased = false
        // Temporarily take over the chord for the live test.
        coordinator.unregisterPushToTalk()
        chordProbe = HotkeyMonitor.shared.register(coordinator.settings.settings.pushToTalk,
                                                   pressed: { chordPressed = true }, released: { chordReleased = true })
    }
    private func stopChordTest() {
        if chordProbe != nil { HotkeyMonitor.shared.unregister(chordProbe); chordProbe = nil; coordinator.registerHotkeys() }
    }

    private func detectAgents() async {
        checkingAgents = true
        defer { checkingAgents = false }
        if let p = coordinator.claudePath {
            claudeVersion = await CLILocator.version(of: p)
            let r = await CLILocator.run(p, ["auth", "status"], timeout: 20)
            claudeLoggedIn = r.stdout.contains("\"loggedIn\": true") || r.stdout.contains("\"loggedIn\":true")
        } else { claudeVersion = nil; claudeLoggedIn = nil }
        if let p = coordinator.codexPath {
            codexVersion = await CLILocator.version(of: p)
            let r = await CLILocator.run(p, ["login", "status"], timeout: 20)
            codexLoggedIn = (r.stdout + r.stderr).localizedCaseInsensitiveContains("logged in")
        } else { codexVersion = nil; codexLoggedIn = nil }
    }
}
