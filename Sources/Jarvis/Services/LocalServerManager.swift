import Foundation
import Observation

/// Owns only servers started from Orbit. Existing servers are left untouched.
@MainActor @Observable
final class LocalServerManager {
    static let shared = LocalServerManager()
    private var process: Subprocess?
    private(set) var starting = false
    private(set) var error: String?

    func startOllama() async -> Bool {
        guard !starting else { return false }
        if (try? await LocalModelService.models(provider: .ollama)) != nil { return true }
        starting = true; error = nil
        defer { starting = false }
        guard process?.isRunning != true else { error = "Ollama si sta avviando. Attendi e premi Ricontrolla."; return false }
        let paths = [CLILocator.find("ollama"), "/Applications/Ollama.app/Contents/Resources/ollama",
                     NSHomeDirectory() + "/Applications/Ollama.app/Contents/Resources/ollama"].compactMap { $0 }
        guard let executable = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            error = "Installa Ollama sul Mac prima di avviare il server."; return false
        }
        var env = CLILocator.childEnvironment
        env["OLLAMA_HOST"] = "127.0.0.1:11434"
        env["OLLAMA_CONTEXT_LENGTH"] = "16384"
        env["OLLAMA_NO_CLOUD"] = "true"
        do {
            let server = try Subprocess(executable: executable, arguments: ["serve"], cwd: AppPaths.root.path, environment: env)
            server.onExit = { [weak self] code in
                Task { @MainActor in
                    guard let self else { return }
                    if code != 0 { self.error = "Ollama non è partito. Verifica che la porta 11434 sia libera e premi Ricontrolla." }
                }
            }
            process = server; server.start()
            for _ in 0..<20 {
                guard !Task.isCancelled else { stop(); return false }
                if (try? await LocalModelService.models(provider: .ollama)) != nil { return true }
                try await Task.sleep(for: .milliseconds(300))
            }
            error = "Il server non risponde ancora. Attendi e premi Ricontrolla."; return false
        } catch {
            self.error = "Non riesco ad avviare Ollama: \(error.localizedDescription)"; return false
        }
    }

    func stop() { process?.kill(); process = nil }
}
