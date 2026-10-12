import SwiftUI
import AppKit

/// One editor is reused for routing and work; changing one never affects the other.
struct ModelConnectionView: View {
    @Binding var selection: CodexModelSelection
    @Binding var cloudModel: String
    let title: String
    let detail: String
    var allowsIntegrations = false
    @State private var models: [String] = []
    @State private var checking = false
    @State private var status = ""
    @State private var connected = false
    @State private var refresh = 0
    @State private var launching = false

    var body: some View {
        Section {
            Text(detail).font(.caption).foregroundStyle(OrbitDesign.secondaryText)
            Picker("Provider", selection: $selection.provider) {
                ForEach(CodexProvider.allCases) { Text($0.title).tag($0) }
            }
            if selection.provider.isLocal {
                LabeledContent("Modello") {
                    HStack(spacing: 8) {
                        TextField("", text: $selection.localModel, prompt: Text("Nome esatto del modello"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 170)
                        if !models.isEmpty {
                            Menu {
                                ForEach(models, id: \.self) { model in
                                    Button(model) { selection.localModel = model }
                                }
                            } label: { Image(systemName: "list.bullet") }
                            .help("Scegli tra i modelli disponibili")
                            .accessibilityLabel("Modelli disponibili")
                        }
                    }
                }
                HStack(spacing: 8) {
                    if checking { ProgressView().controlSize(.small) }
                    else { Image(systemName: connected ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(connected ? OrbitDesign.lime : OrbitDesign.secondaryText) }
                    Text(checking ? "Controllo il server…" : status)
                        .font(.caption).foregroundStyle(OrbitDesign.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Ricontrolla") { refresh += 1 }.disabled(checking)
                }
                HStack {
                    Text(selection.provider == .ollama ? "Server: localhost:11434" : "Server: localhost:1234")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(OrbitDesign.secondaryText)
                    Spacer()
                    if selection.provider == .ollama {
                        Button(launching ? "Avvio…" : "Avvia server") {
                            Task {
                                launching = true
                                let success = await LocalServerManager.shared.startOllama()
                                launching = false
                                if success { refresh += 1 }
                                else { status = LocalServerManager.shared.error ?? "Avvio non riuscito." }
                            }
                        }.disabled(connected || launching)
                    } else {
                        Button("Apri LM Studio") { openProvider() }
                    }
                }
                Text("Scegli un modello che supporta gli strumenti. Per i lavori usa un contesto di almeno 16.384 token. «Avvia server» configura questo contesto per Ollama; se il server è già acceso, imposta il contesto nella sua app. In LM Studio carica il modello e avvia il server locale.")
                    .font(.caption).foregroundStyle(OrbitDesign.secondaryText)
                if allowsIntegrations {
                    Toggle("Includi plugin e integrazioni di Codex", isOn: $selection.includeIntegrations)
                    Text("L’agente locale usa normalmente i file e i comandi del progetto. Attiva questa opzione per aggiungere anche le integrazioni della tua configurazione Codex; richiedono più contesto e risorse.")
                        .font(.caption).foregroundStyle(OrbitDesign.secondaryText)
                }
                if selection.localModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Label("Seleziona o inserisci un modello per attivare questa configurazione.", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(OrbitDesign.warning)
                }
            } else {
                TextField("Modello OpenAI (vuoto = predefinito)", text: $cloudModel)
                Text("Usa l’accesso ChatGPT già configurato in Codex.")
                    .font(.caption).foregroundStyle(OrbitDesign.secondaryText)
            }
        } header: {
            Text(title)
        }
        .task(id: "\(selection.provider.rawValue)-\(refresh)") { await discover() }
    }

    private func discover() async {
        let provider = selection.provider
        models = []; connected = false; status = ""; checking = provider.isLocal
        guard provider.isLocal else { return }
        do {
            let found = try await LocalModelService.models(provider: provider)
            guard !Task.isCancelled, selection.provider == provider else { return }
            models = found; connected = true; checking = false
            status = found.isEmpty ? "Server collegato. Nessun modello disponibile." : "Server collegato · \(found.count) modelli disponibili"
        } catch {
            guard !Task.isCancelled, selection.provider == provider else { return }
            checking = false; status = error.localizedDescription
        }
    }

    private func openProvider() {
        let name = selection.provider == .ollama ? "Ollama" : "LM Studio"
        let paths = ["/Applications/\(name).app", NSHomeDirectory() + "/Applications/\(name).app"]
        guard let path = paths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            status = "\(name) non è installato nella cartella Applicazioni."; return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}
