import Foundation
import Darwin

/// Minimal subprocess wrapper built on posix_spawn so that every child gets its own
/// process group. Killing `-pgid` then takes the entire tree (claude → node → shells),
/// which Foundation.Process cannot do — that is why this exists (acceptance #7).
final class Subprocess: @unchecked Sendable {
    let pid: pid_t
    private let stdoutFD: Int32
    private let stderrFD: Int32
    private let queue = DispatchQueue(label: "jarvis.subprocess", qos: .userInitiated)
    private var stdoutSource: DispatchSourceRead?
    private var stderrSource: DispatchSourceRead?
    private var buffer = Data()
    private var errBuffer = Data()
    private var exited = false
    private let lock = NSLock()
    private let inputQueue = DispatchQueue(label: "orbit.subprocess.input")
    private var inputFD: Int32?

    var onLine: (@Sendable (String) -> Void)?
    var onStderr: (@Sendable (String) -> Void)?
    var onExit: (@Sendable (Int32) -> Void)?

    struct SpawnError: Error { let code: Int32 }

    init(executable: String, arguments: [String], cwd: String?, environment: [String: String], interactiveInput: Bool = false) throws {
        var outPipe: [Int32] = [0, 0], errPipe: [Int32] = [0, 0]
        guard pipe(&outPipe) == 0 else { throw SpawnError(code: errno) }
        guard pipe(&errPipe) == 0 else {
            let code = errno
            close(outPipe[0]); close(outPipe[1])
            throw SpawnError(code: code)
        }
        var inPipe: [Int32] = [0, 0]
        if interactiveInput {
            guard pipe(&inPipe) == 0 else {
                let code = errno
                [outPipe[0], outPipe[1], errPipe[0], errPipe[1]].forEach { Darwin.close($0) }
                throw SpawnError(code: code)
            }
            // A disconnected agent must produce EPIPE, never SIGPIPE in Orbit.
            guard fcntl(inPipe[1], F_SETNOSIGPIPE, 1) == 0 else {
                let code = errno
                (outPipe + errPipe + inPipe).forEach { Darwin.close($0) }
                throw SpawnError(code: code)
            }
        }
        // Drain everything available without blocking the serial I/O queue.
        _ = fcntl(outPipe[0], F_SETFL, O_NONBLOCK)
        _ = fcntl(errPipe[0], F_SETFL, O_NONBLOCK)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        // stdin ← /dev/null (codex otherwise blocks on "Reading additional input from stdin")
        if interactiveInput {
            posix_spawn_file_actions_adddup2(&actions, inPipe[0], 0)
            posix_spawn_file_actions_addclose(&actions, inPipe[0])
            posix_spawn_file_actions_addclose(&actions, inPipe[1])
        } else { posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0) }
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        posix_spawn_file_actions_addclose(&actions, outPipe[1])
        posix_spawn_file_actions_addclose(&actions, errPipe[1])
        posix_spawn_file_actions_addclose(&actions, outPipe[0])
        posix_spawn_file_actions_addclose(&actions, errPipe[0])
        if let cwd { posix_spawn_file_actions_addchdir_np(&actions, cwd) }

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attr, 0) // own process group, pgid == pid

        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }

        var child: pid_t = 0
        let rc = posix_spawn(&child, executable, &actions, &attr, argv, envp)
        close(outPipe[1]); close(errPipe[1])
        if interactiveInput { Darwin.close(inPipe[0]) }
        guard rc == 0 else {
            close(outPipe[0]); close(errPipe[0])
            if interactiveInput { Darwin.close(inPipe[1]) }
            throw SpawnError(code: rc)
        }

        pid = child
        stdoutFD = outPipe[0]
        stderrFD = errPipe[0]
        inputFD = interactiveInput ? inPipe[1] : nil
    }

    nonisolated(unsafe) private static var live: [pid_t: Subprocess] = [:]
    private static let liveLock = NSLock()

    func start() {
        Self.liveLock.lock(); Self.live[pid] = self; Self.liveLock.unlock()
        stdoutSource = makeSource(fd: stdoutFD, isErr: false)
        stderrSource = makeSource(fd: stderrFD, isErr: true)
        stdoutSource?.resume(); stderrSource?.resume()
        // Reap on a background thread; no polling.
        let pid = self.pid
        Thread.detachNewThread { [weak self] in
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            let code: Int32
            if (status & 0x7f) == 0 { code = (status >> 8) & 0xff } else { code = 128 + (status & 0x7f) }
            self?.finish(code: code)
        }
    }

    private func makeSource(fd: Int32, isErr: Bool) -> DispatchSourceRead {
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in
            guard let self else { src.cancel(); return }   // owner gone → stop, or the source spins at EOF
            self.readAvailable(fd: fd, isErr: isErr, source: src)
        }
        src.setCancelHandler { close(fd) }
        return src
    }

    private func drainLines(isErr: Bool) -> [String] {
        var out: [String] = []
        while let nl = (isErr ? errBuffer : buffer).firstIndex(of: 0x0A) {
            let lineData = (isErr ? errBuffer : buffer)[..<nl]
            if let s = String(data: lineData, encoding: .utf8), !s.isEmpty { out.append(s) }
            if isErr { errBuffer.removeSubrange(...nl) } else { buffer.removeSubrange(...nl) }
        }
        return out
    }

    /// Called only on the serial I/O queue. Delivery stays in order, including the final partial line.
    private func readAvailable(fd: Int32, isErr: Bool, source: DispatchSourceRead?) {
        guard source?.isCancelled != true else { return }
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n > 0 {
                if isErr { errBuffer.append(contentsOf: chunk[0..<n]) } else { buffer.append(contentsOf: chunk[0..<n]) }
                for line in drainLines(isErr: isErr) { (isErr ? onStderr : onLine)?(line) }
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                if n == 0 || errno != EAGAIN { source?.cancel() }
                break
            }
        }
    }

    private func finish(code: Int32) {
        lock.lock()
        if exited { lock.unlock(); return }
        exited = true
        lock.unlock()
        closeInput()
        // waitpid has returned: drain the pipes before flushing tails and delivering onExit.
        queue.async { [self] in
            readAvailable(fd: stdoutFD, isErr: false, source: stdoutSource)
            readAvailable(fd: stderrFD, isErr: true, source: stderrSource)
            if let tail = String(data: buffer, encoding: .utf8), !tail.isEmpty { onLine?(tail) }
            if let tail = String(data: errBuffer, encoding: .utf8), !tail.isEmpty { onStderr?(tail) }
            buffer.removeAll(); errBuffer.removeAll()
            stdoutSource?.cancel(); stderrSource?.cancel()
            onExit?(code)
            Self.liveLock.lock(); Self.live[pid] = nil; Self.liveLock.unlock()
        }
    }

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return !exited }

    /// Ordered writes run off MainActor. The separate queue keeps output draining
    /// while a large prompt waits for the agent to read its input.
    func send(_ data: Data, completion: @escaping @Sendable (Int32?) -> Void) {
        inputQueue.async { [self] in
            guard let fd = inputFD else { completion(EBADF); return }
            var failure: Int32?
            data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if n > 0 { offset += n }
                    else if n < 0 && errno == EINTR { continue }
                    else { failure = errno; break }
                }
            }
            completion(failure)
        }
    }

    func closeInput() {
        inputQueue.async { [self] in
            if let fd = inputFD { Darwin.close(fd); inputFD = nil }
        }
    }

    /// SIGINT the whole group, then SIGKILL after `grace` seconds if still alive.
    func interrupt(grace: TimeInterval = 3) {
        guard isRunning else { return }
        Darwin.kill(-pid, SIGINT)
        let pid = self.pid
        queue.asyncAfter(deadline: .now() + grace) { [weak self] in
            if self?.isRunning == true { Darwin.kill(-pid, SIGKILL) }
        }
    }

    func kill() { if isRunning { Darwin.kill(-pid, SIGKILL) } }

    static func killGroup(_ pid: Int32) { Darwin.kill(-pid, SIGKILL) }
    static func isAlive(_ pid: Int32) -> Bool { Darwin.kill(pid, 0) == 0 }
}
