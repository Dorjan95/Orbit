import Darwin
import Foundation

public struct Invocation: Sendable {
  public var executable: URL
  public var arguments: [String]
  public var directory: URL
  public var input: String
  public var environment: [String: String]?
  public init(
    executable: URL, arguments: [String], directory: URL, input: String = "",
    environment: [String: String]? = nil
  ) {
    self.executable = executable
    self.arguments = arguments
    self.directory = directory
    self.input = input
    self.environment = environment
  }
}
public enum ProcessSignal: Sendable {
  case started
  case output(String)
  case diagnostic(String)
  case finished(Int32)
  case failed(String)
}
/// Owns only the process it launches. Persisted session IDs are never used as OS process IDs.
public final class ProcessStream: @unchecked Sendable {
  private let lock = NSLock()
  private var child: Process?
  private var cancelled = false
  private var stdin: FileHandle?
  private let writes = DispatchQueue(label: "orbit.process.stdin")
  public init() {}
  public func cancel() {
    lock.lock()
    cancelled = true
    let process = child
    lock.unlock()
    guard let process, process.isRunning else { return }
    let pid = process.processIdentifier
    if getpgid(pid) == pid { kill(-pid, SIGTERM) } else { process.terminate() }
    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
      guard process.isRunning, process.processIdentifier == pid else { return }
      // Foundation creates a process group on macOS. Only signal that group when it is ours.
      if getpgid(pid) == pid { kill(-pid, SIGKILL) } else { kill(pid, SIGKILL) }
    }
  }
  public func send(_ line: String) async throws {
    try await withCheckedThrowingContinuation { (reply: CheckedContinuation<Void, Error>) in
      writes.async { [self] in
        lock.lock()
        let handle = cancelled ? nil : stdin
        lock.unlock()
        do {
          guard let handle else {
            throw AgentError.execution("La connessione all’agente è chiusa.")
          }
          try handle.write(contentsOf: Data((line + "\n").utf8))
          reply.resume()
        } catch { reply.resume(throwing: error) }
      }
    }
  }
  public func closeInput() {
    writes.async { [self] in
      lock.lock()
      let handle = stdin
      stdin = nil
      lock.unlock()
      try? handle?.close()
    }
  }
  public func events(for invocation: Invocation, interactive: Bool = false) -> AsyncStream<
    ProcessSignal
  > {
    AsyncStream { continuation in
      DispatchQueue.global(qos: .userInitiated).async { [self] in
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        let input = Pipe()
        process.executableURL = invocation.executable
        process.arguments = invocation.arguments
        process.currentDirectoryURL = invocation.directory
        process.environment = invocation.environment
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = input
        lock.lock()
        child = process
        let stop = cancelled
        lock.unlock()
        if stop {
          continuation.yield(.finished(130))
          continuation.finish()
          return
        }
        do { try process.run() } catch {
          continuation.yield(.failed(error.localizedDescription))
          continuation.finish()
          return
        }
        lock.lock()
        let stopAfterLaunch = cancelled
        lock.unlock()
        if stopAfterLaunch { cancel() }
        if interactive {
          lock.lock()
          stdin = input.fileHandleForWriting
          lock.unlock()
          continuation.yield(.started)
        }
        let readers = DispatchGroup()
        for (pipe, diagnostic) in [(output, false), (errors, true)] {
          readers.enter()
          DispatchQueue.global().async {
            var pending = Data()
            while true {
              let bytes = pipe.fileHandleForReading.availableData
              if bytes.isEmpty { break }
              pending.append(bytes)
              if interactive && pending.count > 16 * 1024 * 1024 {
                continuation.yield(
                  .failed("Una risposta del protocollo Codex supera il limite di 16 MiB."))
                self.cancel()
                break
              }
              while let newline = pending.firstIndex(of: 10) {
                let line = String(decoding: pending[..<newline], as: UTF8.self)
                pending.removeSubrange(...newline)
                continuation.yield(diagnostic ? .diagnostic(line) : .output(line))
              }
            }
            if !pending.isEmpty {
              let line = String(decoding: pending, as: UTF8.self)
              continuation.yield(diagnostic ? .diagnostic(line) : .output(line))
            }
            try? pipe.fileHandleForReading.close()
            readers.leave()
          }
        }
        if !interactive {
          DispatchQueue.global().async {
            try? input.fileHandleForWriting.write(contentsOf: Data(invocation.input.utf8))
            try? input.fileHandleForWriting.close()
          }
        }
        process.waitUntilExit()
        readers.wait()
        closeInput()
        continuation.yield(.finished(process.terminationStatus))
        continuation.finish()
        lock.lock()
        child = nil
        lock.unlock()
      }
    }
  }
  public func collect(_ invocation: Invocation) async throws -> String {
    try await withTaskCancellationHandler {
      var lines: [String] = []
      var diagnostics: [String] = []
      var status: Int32 = -1
      for await event in events(for: invocation) {
        try Task.checkCancellation()
        switch event {
        case .started: break
        case .output(let line): lines.append(line)
        case .diagnostic(let line): diagnostics.append(line)
        case .failed(let message): throw AgentError.execution(message)
        case .finished(let code): status = code
        }
      }
      try Task.checkCancellation()
      guard status == 0 else {
        throw AgentError.execution(
          diagnostics.suffix(12).joined(separator: "\n").isEmpty
            ? "L’agente è terminato con codice \(status)."
            : diagnostics.suffix(12).joined(separator: "\n"))
      }
      return lines.joined(separator: "\n")
    } onCancel: {
      self.cancel()
    }
  }
}
public enum AgentError: LocalizedError, Sendable {
  case missing(Agent)
  case execution(String)
  case invalidReply, noLocalModel, invalidDirectory
  public var errorDescription: String? {
    switch self {
    case .missing(let agent):
      "\(agent.rawValue.capitalized) CLI non trovato. Installa il CLI o scegli il suo percorso nelle impostazioni."
    case .execution(let message): message
    case .invalidReply:
      "L’interprete non ha restituito una decisione valida. Riprova indicando il progetto e la richiesta."
    case .noLocalModel: "Seleziona un modello locale nelle impostazioni Modelli."
    case .invalidDirectory: "La cartella del progetto non esiste o non è accessibile."
    }
  }
}
