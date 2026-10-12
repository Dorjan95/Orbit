import Foundation

/// Runs the explicitly configured project check; success is its actual exit code.
@MainActor
final class VerificationBackend: AgentBackend {
    let capabilities = AgentBackendCapabilities(resume: false, liveFollowup: false, interactiveApprovals: false, steering: false)
    var pid: Int32? { process?.pid }
    var isRunning: Bool { process?.isRunning ?? false }
    private var process: Subprocess?
    private var deadline: Task<Void, Never>?
    private var output = ""
    private var timedOut = false
    private var cancelled = false
    private var log: FileHandle?
    private let sessionID: String
    private let timeout: Duration
    private let onEvent: @MainActor (AgentEvent) -> Void
    private let onExit: @MainActor (Int32, String) -> Void
    private enum Delivery: Sendable { case line(String), exit(Int32) }

    init(sessionID: String, timeout: Duration = .seconds(300), onEvent: @escaping @MainActor (AgentEvent) -> Void,
         onExit: @escaping @MainActor (Int32, String) -> Void) {
        self.sessionID = sessionID; self.timeout = timeout; self.onEvent = onEvent; self.onExit = onExit
    }

    func start(_ request: AgentRunRequest) throws {
        guard process == nil else { throw AgentBackendError.alreadyRunning }
        let p = try Subprocess(executable: "/bin/zsh", arguments: ["-c", request.task], cwd: request.cwd,
                               environment: CLILocator.childEnvironment)
        let url = AppPaths.log(for: sessionID)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        log = try? FileHandle(forWritingTo: url); _ = try? log?.seekToEnd()
        log?.write(Data(("[verification] " + request.task + "\n").utf8))
        let (stream, continuation) = AsyncStream<Delivery>.makeStream()
        p.onLine = { continuation.yield(.line($0)) }
        p.onStderr = { continuation.yield(.line("[stderr] " + $0)) }
        p.onExit = { continuation.yield(.exit($0)); continuation.finish() }
        Task { @MainActor [weak self] in
            for await delivery in stream {
                guard let self else { return }
                switch delivery {
                case .line(let line):
                    log?.write(Data((line + "\n").utf8))
                    output = String((output + line + "\n").suffix(64000))
                case .exit(let code):
                    deadline?.cancel(); deadline = nil
                    try? log?.close(); log = nil
                    if timedOut { output += "\nVerifica interrotta: limite di tempo superato." }
                    else if cancelled { output += "\nVerifica annullata." }
                    else { output += "\nVerifica terminata con codice \(code)." }
                    // Only a real check failure is eligible for automatic repair.
                    onEvent(.turnEnded(cancelled ? .cancelled : timedOut ? .blocked : code == 0 ? .completed : .failed))
                    onEvent(.result(text: output, isError: code != 0 || timedOut || cancelled))
                    onExit(code, output)
                }
            }
        }
        process = p; p.start()
        deadline = Task { @MainActor [weak self, timeout] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard let self else { return }; timedOut = true; process?.interrupt()
        }
    }

    func sendFollowup(_ task: String) throws { throw AgentBackendError.liveFollowupUnavailable }
    func cancel() {
        deadline?.cancel()
        if cancelled { process?.kill() } else { cancelled = true; process?.interrupt() }
    }
    func close() { cancelled = true; deadline?.cancel(); process?.kill() }
}
