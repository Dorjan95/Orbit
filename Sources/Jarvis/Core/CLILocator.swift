import Foundation

/// Finds `claude` / `codex` on PATH and the usual extra install locations (§3.4).
enum CLILocator {
    /// User-level installs first: a system-wide `/usr/local/bin/claude` is often a stale npm copy (2.1.111 vs 2.1.280
    /// on 29/09/2026) that also needs `node` on PATH. fnm's default alias gives child sessions a Node for `npx` MCP servers.
    static let extraDirs: [String] = [
        "~/.npm-global/bin", "~/.local/bin", "~/.claude/local", "~/.bun/bin", "~/.volta/bin", "~/.codex/bin",
        "~/.local/share/fnm/aliases/default/bin",
        "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    ].map { ($0 as NSString).expandingTildeInPath }

    static var searchPath: String {
        let env = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        var seen = Set<String>(); var out: [String] = []
        for d in env + extraDirs where seen.insert(d).inserted { out.append(d) }
        return out.joined(separator: ":")
    }

    static func find(_ name: String, override: String? = nil) -> String? {
        if let override, !override.isEmpty, FileManager.default.isExecutableFile(atPath: override) { return override }
        for dir in searchPath.split(separator: ":") {
            let p = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        // Finder launches have a minimal PATH; the desktop app may be the only CLI installation.
        if name == "codex" {
            for path in bundledCodexPaths where FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    static let bundledCodexPaths = [
        "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
        "/Applications/Codex.app/Contents/Resources/codex",
        NSHomeDirectory() + "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
        NSHomeDirectory() + "/Applications/Codex.app/Contents/Resources/codex",
    ]

    /// Environment for child CLIs: inherit, widen PATH, and make sure no API keys leak in (§9 #9).
    static var childEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPath
        env["HOME"] = NSHomeDirectory()
        env.removeValue(forKey: "ANTHROPIC_API_KEY")
        env.removeValue(forKey: "OPENAI_API_KEY")
        env.removeValue(forKey: "CODEX_API_KEY")
        env["TERM"] = "dumb"
        env["NO_COLOR"] = "1"
        return env
    }

    /// Run a CLI to completion and capture stdout (used for `--version`, `auth status`, orchestrator).
    static func run(_ executable: String, _ args: [String], cwd: String? = nil, timeout: TimeInterval = 60, extraEnv: [String: String] = [:]) async -> (code: Int32, stdout: String, stderr: String) {
        await withCheckedContinuation { cont in
            let out = OutputBox(); let err = OutputBox()
            do {
                let p = try Subprocess(executable: executable, arguments: args, cwd: cwd, environment: childEnvironment.merging(extraEnv) { $1 })
                p.onLine = { out.append($0) }
                p.onStderr = { err.append($0) }
                let done = DoneBox()
                p.onExit = { code in
                    if done.claim() { cont.resume(returning: (code, out.joined, err.joined)) }
                }
                p.start()
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if p.isRunning { p.kill() }
                }
            } catch {
                cont.resume(returning: (-1, "", "spawn failed: \(error)"))
            }
        }
    }

    static func version(of executable: String) async -> String? {
        let r = await run(executable, ["--version"], timeout: 15)
        let s = (r.stdout + r.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s.components(separatedBy: "\n").first
    }
}

final class OutputBox: @unchecked Sendable {
    private var lines: [String] = []; private let lock = NSLock()
    func append(_ s: String) { lock.lock(); lines.append(s); lock.unlock() }
    var joined: String { lock.lock(); defer { lock.unlock() }; return lines.joined(separator: "\n") }
}
final class DoneBox: @unchecked Sendable {
    private var done = false; private let lock = NSLock()
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}
