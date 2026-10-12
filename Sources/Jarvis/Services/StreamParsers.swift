import Foundation

/// Events normalised across both agents.
enum AgentEvent: Equatable, Sendable {
    case sessionID(String)
    case activity(String)          // "Edit src/Hero.tsx"
    case text(String)              // assistant prose
    case needsInput                // permission denial / blocked
    case result(text: String, isError: Bool)
    case turnEnded(BackendTurnOutcome)
    case streamComplete
    case approvalRequested(AgentApproval)
    case approvalExpired(UUID)
}

/// Parser for `claude -p --output-format stream-json --verbose` NDJSON.
/// Written against Tests/JarvisTests/Fixtures/claude-stream.ndjson captured from claude 2.1.239.
enum ClaudeStreamParser {
    static func parse(line: String) -> [AgentEvent] {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var events: [AgentEvent] = []
        let type = obj["type"] as? String ?? ""

        switch type {
        case "system":
            if obj["subtype"] as? String == "init", let sid = obj["session_id"] as? String { events.append(.sessionID(sid)) }
            if obj["subtype"] as? String == "task_summary", let d = obj["detail"] as? String, !d.isEmpty { events.append(.activity(d)) }
        case "assistant":
            guard let msg = obj["message"] as? [String: Any], let content = msg["content"] as? [[String: Any]] else { break }
            for block in content {
                switch block["type"] as? String {
                case "tool_use":
                    let name = block["name"] as? String ?? "Tool"
                    let input = block["input"] as? [String: Any] ?? [:]
                    events.append(.activity(describeTool(name, input)))
                case "text":
                    if let t = block["text"] as? String, !t.isEmpty { events.append(.text(t)) }
                default: break
                }
            }
        case "result":
            let isError = obj["is_error"] as? Bool ?? false
            let text = obj["result"] as? String ?? (obj["subtype"] as? String ?? "")
            if let sid = obj["session_id"] as? String { events.append(.sessionID(sid)) }
            if let denials = obj["permission_denials"] as? [[String: Any]], !denials.isEmpty { events.append(.needsInput) }
            events.append(.result(text: text, isError: isError))
        default:
            break
        }
        return events
    }

    static func describeTool(_ name: String, _ input: [String: Any]) -> String {
        func short(_ p: String) -> String {
            let parts = p.split(separator: "/")
            return parts.suffix(3).joined(separator: "/")
        }
        let verb = italianVerb(name)
        if let fp = input["file_path"] as? String { return "\(verb) \(short(fp))" }
        if let cmd = input["command"] as? String { return "Esegue \(cmd.prefix(60))" }
        if let pat = input["pattern"] as? String { return "\(verb) \(pat.prefix(40))" }
        if let q = input["query"] as? String { return "\(verb) \(q.prefix(40))" }
        if let d = input["description"] as? String { return "\(verb) \(d.prefix(50))" }
        return verb
    }

    /// The activity line under a running card: Claude's tool names read as Italian verbs; MCP and unknown tools keep their name.
    static func italianVerb(_ tool: String) -> String {
        switch tool {
        case "Read": "Legge"
        case "Write": "Scrive"
        case "Edit", "MultiEdit", "NotebookEdit": "Modifica"
        case "Grep", "Glob": "Cerca"
        case "WebSearch": "Cerca sul web"
        case "WebFetch": "Apre"
        case "Task", "Agent": "Sotto-agente"
        case "TodoWrite": "Aggiorna il piano"
        case "Bash": "Esegue"
        default: tool
        }
    }
}

/// Parser for `codex exec --json` JSONL (codex-cli 0.147).
/// Written against Tests/JarvisTests/Fixtures/codex-stream.ndjson.
enum CodexStreamParser {
    static func parse(line: String) -> [AgentEvent] {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let type = obj["type"] as? String ?? ""
        switch type {
        case "thread.started":
            if let id = obj["thread_id"] as? String { return [.sessionID(id)] }
        case "item.started", "item.completed":
            guard let item = obj["item"] as? [String: Any] else { return [] }
            switch item["type"] as? String {
            case "agent_message":
                if let t = item["text"] as? String, !t.isEmpty { return [.text(t)] }
            case "file_change":
                let paths = (item["changes"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
                if let p = paths.first { return [.activity("Modifica \(p.split(separator: "/").suffix(2).joined(separator: "/"))")] }
            case "command_execution":
                if let c = item["command"] as? String { return [.activity("Esegue \(c.prefix(60))")] }
            case "mcp_tool_call":
                let server = item["server"] as? String ?? "MCP"
                let tool = item["tool"] as? String ?? "strumento"
                return [.activity("Usa \(server): \(tool)")]
            case "web_search":
                return [.activity("Cerca sul web")]
            case "reasoning":
                return [.activity("Sta ragionando…")]
            default: break
            }
        case "turn.completed":
            return [.result(text: "", isError: false)]
        case "turn.failed", "error":
            let msg = (obj["error"] as? [String: Any])?["message"] as? String ?? obj["message"] as? String ?? "Errore di Codex"
            return [.result(text: msg, isError: true)]
        default: break
        }
        return []
    }
}

/// What to show the user when a session ends: the site it left running on localhost, otherwise the last HTML page
/// it wrote or edited. Nil if it opened something itself or produced nothing to look at. Sessions were told to open
/// their result and ignored it (29/09, the clock page), so Jarvis does it from the session log.
enum SessionResult {
    static func viewable(ndjson: String, resultText: String, projectPath: String? = nil) -> URL? {
        var page: String?
        var openedItself = false
        for line in ndjson.split(separator: "\n") {
            guard let d = line.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            let type = o["type"] as? String
            let method = o["method"] as? String
            if type == "thread.started" || method == "turn/started" || (type == "system" && o["subtype"] as? String == "init") {
                page = nil; openedItself = false
            }
            if method == "item/completed", let params = o["params"] as? [String: Any], let item = params["item"] as? [String: Any] {
                if item["type"] as? String == "fileChange", item["status"] as? String == "completed" {
                    for change in item["changes"] as? [[String: Any]] ?? [] {
                        if let path = change["path"] as? String, (change["kind"] as? [String: Any])?["type"] as? String != "delete",
                           ["html", "htm"].contains((path as NSString).pathExtension.lowercased()) { page = path }
                    }
                }
                if item["type"] as? String == "commandExecution", item["exitCode"] as? Int == 0,
                   let cmd = item["command"] as? String,
                   cmd.range(of: #"(^|[;&|\s'"])(/usr/bin/)?open\s"#, options: .regularExpression) != nil { openedItself = true }
            }
            if type == "item.completed", let item = o["item"] as? [String: Any] {
                if item["type"] as? String == "file_change", item["status"] as? String != "failed" {
                    for change in item["changes"] as? [[String: Any]] ?? [] {
                        if let path = change["path"] as? String, change["kind"] as? String != "delete",
                           ["html", "htm"].contains((path as NSString).pathExtension.lowercased()) { page = path }
                    }
                }
                if item["type"] as? String == "command_execution", item["exit_code"] as? Int == 0,
                   let cmd = item["command"] as? String,
                   cmd.range(of: #"(^|[;&|\s'"])(/usr/bin/)?open\s"#, options: .regularExpression) != nil { openedItself = true }
            }
            guard type == "assistant", let m = o["message"] as? [String: Any],
                  let content = m["content"] as? [[String: Any]] else { continue }
            for b in content where b["type"] as? String == "tool_use" {
                let input = b["input"] as? [String: Any] ?? [:]
                if let fp = input["file_path"] as? String, ["html", "htm"].contains((fp as NSString).pathExtension.lowercased()) { page = fp }
                if let cmd = input["command"] as? String, cmd.range(of: #"(^|[;&|]\s*)open\s"#, options: .regularExpression) != nil { openedItself = true }
            }
        }
        if openedItself { return nil }
        if let r = resultText.range(of: #"https?://(localhost|127\.0\.0\.1)(:\d+)?[^\s)`'"]*"#, options: .regularExpression) {
            return URL(string: String(resultText[r]))
        }
        return page.map { path in
            if !(path as NSString).isAbsolutePath, let projectPath {
                return URL(fileURLWithPath: projectPath, isDirectory: true).appendingPathComponent(path)
            }
            return URL(fileURLWithPath: path)
        }
    }
}

/// What gets said out loud while a session works: the agent's own short narration when there is a fresh one,
/// otherwise the current activity turned into a spoken Italian phrase. Never reads commands, patterns or long paths.
enum ProgressSpeech {
    /// A narration line is worth saying only if it is short, plain prose: no code fences, no markdown lists, no multi-line dumps.
    static func narration(from text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 160, !t.contains("```"), !t.contains("\n"),
              !t.hasPrefix("-"), !t.hasPrefix("#"), !t.hasPrefix("|") else { return nil }
        return t.replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "**", with: "")
    }

    static func phrase(forActivity a: String) -> String? {
        let a = a.trimmingCharacters(in: .whitespaces)
        guard !a.isEmpty else { return nil }
        func object(after verb: String) -> String {
            let rest = a.dropFirst(verb.count).trimmingCharacters(in: .whitespaces)
            // Only the file name, never the full path: "src/components/Hero.tsx" → "Hero.tsx".
            let last = rest.split(separator: "/").last.map(String.init) ?? rest
            return last.count <= 40 && !last.contains(" ") ? last : ""
        }
        let table: [(String, String)] = [
            ("Modifica", "sto modificando"), ("Scrive", "sto scrivendo"), ("Legge", "sto leggendo"),
            ("Cerca sul web", "sto cercando sul web"), ("Cerca", "sto cercando nel codice"), ("Apre", "sto leggendo una pagina web"),
            ("Esegue", "sto lanciando un comando"), ("Sotto-agente", "ho passato un pezzo a un sotto-agente"),
            ("Aggiorna il piano", "sto aggiornando il piano"),
        ]
        for (verb, spoken) in table where a.hasPrefix(verb) {
            // Search patterns, shell commands and web queries stay unsaid: they sound terrible read aloud.
            if ["Esegue", "Cerca", "Cerca sul web", "Apre", "Sotto-agente", "Aggiorna il piano"].contains(verb) { return spoken }
            let o = object(after: verb)
            return o.isEmpty ? spoken + " un file" : "\(spoken) \(o)"
        }
        return "ci sto lavorando"
    }
}
