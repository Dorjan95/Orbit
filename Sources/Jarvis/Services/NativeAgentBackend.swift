import Foundation

/// One verified turn per process. Native CLI authentication and transcripts stay
/// with Codex/Claude; Orbit owns durable input, approvals and interruption.
@MainActor
final class NativeAgentBackend: AgentBackend {
    let capabilities = AgentBackendCapabilities.nativeCLI
    let agent: AgentKind
    var pid: Int32? { process?.pid }
    var isRunning: Bool { process?.isRunning ?? false }
    var canSteer: Bool { isRunning && promptSent && remoteID != nil && (agent == .claude || remoteTurnID != nil) && !terminal && !steeringRequested && !stopping && !failed }
    var steeringSettled: Bool { steeringRequested && interruptAcknowledged && terminal && !failed && !stopping && inputClosed }

    private enum Request { case initialize, thread, prompt, interrupt }
    private enum Delivery: Sendable { case line(String), exit(Int32), writeError(Int32) }
    private struct Permission {
        let approval: AgentApproval
        let method: String
        let payload: [String: Any]
    }
    private var process: Subprocess?
    private var request: AgentRunRequest?
    private var log: FileHandle?
    private var deadline: Task<Void, Never>?
    private var continuation: AsyncStream<Delivery>.Continuation?
    private var requests: [AgentRequestID: Request] = [:]
    private var permissions: [UUID: Permission] = [:]
    private var seenPermissionIDs = Set<AgentRequestID>()
    private var nextID: Int64 = 0
    private var remoteID: String?
    private var remoteTurnID: String?
    private var text = ""
    private var messageTexts: [String: String] = [:]
    private var items: [String: [String: Any]] = [:]
    private var promptSent = false
    private var terminal = false
    private var terminalOutcome: BackendTurnOutcome?
    private var steeringRequested = false
    private var interruptAcknowledged = false
    private var inputClosed = false
    private var stopping = false
    private var failed = false
    private let sessionID: String
    private let onEvent: @MainActor (AgentEvent) -> Void
    private let onExit: @MainActor (Int32, String) -> Void

    init(sessionID: String, agent: AgentKind, onEvent: @escaping @MainActor (AgentEvent) -> Void,
         onExit: @escaping @MainActor (Int32, String) -> Void) {
        self.sessionID = sessionID; self.agent = agent; self.onEvent = onEvent; self.onExit = onExit
    }

    nonisolated static func guidance(_ extra: String?) -> String {
        let base = AgentRunner.sessionGuidance.replacingOccurrences(
            of: "You are run headlessly by a voice assistant; nobody can answer questions, so make sensible decisions and finish the job.",
            with: "You work for Orbit. Make sensible decisions and finish the job. Tool permissions are shown to the user in Orbit; request the needed approval instead of bypassing restrictions.")
        return extra.map { base + "\n\n" + $0 } ?? base
    }

    nonisolated static func arguments(for request: AgentRunRequest) -> [String] {
        if request.configuration.agent == .codex {
            let backend = request.configuration.codex ?? CodexBackend(model: request.configuration.model ?? "")
            var args = ["app-server", "--listen", "stdio://", "-c", "features.shell_snapshot=false",
                        "-c", "model_provider=\"\(backend.provider.rawValue)\""]
            args += backend.workerIsolationArguments
            if backend.provider.isLocal { args += ["-c", "model_context_window=16384", "-c", "model_auto_compact_token_limit=12000"] }
            return args
        }
        var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                    "--permission-prompt-tool", "stdio", "--append-system-prompt", guidance(request.guidance),
                    "--permission-mode", request.configuration.permissionMode == .bypassPermissions ? "bypassPermissions" : "default"]
        if let resume = request.resume { args += ["--resume", resume] }
        if let model = request.configuration.model, !model.isEmpty { args += ["--model", model] }
        return args
    }

    func start(_ request: AgentRunRequest) throws {
        guard process == nil else { throw AgentBackendError.alreadyRunning }
        guard agent.isAvailable, request.configuration.agent == agent, request.configuration.readOnly != true else {
            throw AgentBackendError.wrongAgent
        }
        self.request = request
        // Claude needs a durable UUID before any prompt; resumed sessions retain theirs.
        if agent == .claude { remoteID = request.resume ?? UUID().uuidString }
        var args = Self.arguments(for: request)
        if agent == .claude && request.resume == nil { args += ["--session-id", remoteID!] }
        let p = try Subprocess(executable: request.executable, arguments: args, cwd: request.cwd,
            environment: CLILocator.childEnvironment, interactiveInput: true)
        let logURL = AppPaths.log(for: sessionID)
        if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
        log = try? FileHandle(forWritingTo: logURL); _ = try? log?.seekToEnd()
        let logHandle = log
        let (stream, consumer) = AsyncStream<Delivery>.makeStream()
        continuation = consumer
        p.onLine = { line in
            logHandle?.write(Data((line + "\n").utf8)); consumer.yield(.line(line))
        }
        p.onStderr = { line in logHandle?.write(Data(("[stderr] " + line + "\n").utf8)) }
        p.onExit = { code in consumer.yield(.exit(code)); consumer.finish() }
        Task { @MainActor [weak self] in
            for await delivery in stream {
                guard let self else { return }
                switch delivery {
                case .line(let line): receive(line)
                case .writeError(let code): fail("Collegamento con \(agent.displayName) interrotto (\(code)).")
                case .exit(let code):
                    if !stopping && !failed && (!terminal || !inputClosed || (steeringRequested && !steeringSettled)) {
                        fail("\(agent.displayName) si è chiuso prima della conclusione verificata del turno.")
                    }
                    expirePermissions(); deadline?.cancel(); deadline = nil
                    try? log?.close(); log = nil; continuation = nil
                    onExit(code, text)
                }
            }
        }
        process = p; p.start()
        if agent == .codex {
            rpc(.initialize, method: "initialize", params: ["clientInfo": ["name": "orbit", "title": "Orbit", "version": "0.1"],
                "capabilities": ["experimentalApi": false]])
        } else { control(.initialize, payload: ["subtype": "initialize", "hooks": NSNull()]) }
        armDeadline(seconds: 30, message: "\(agent.displayName) non ha completato l'avvio del collegamento interattivo. Verifica la versione della CLI.")
    }

    private func send(_ object: [String: Any]) {
        guard !inputClosed, let process, let consumer = continuation else { return }
        do {
            var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]); data.append(10)
            process.send(data) { code in if let code { consumer.yield(.writeError(code)) } }
        } catch { fail("Messaggio del protocollo non valido.") }
    }
    private func rpc(_ kind: Request, method: String, params: [String: Any]) {
        nextID += 1; let id = AgentRequestID.number(nextID); requests[id] = kind
        send(["id": id.wireValue, "method": method, "params": params])
    }
    private func control(_ kind: Request, payload: [String: Any]) {
        let id = AgentRequestID.string(UUID().uuidString); requests[id] = kind
        send(["type": "control_request", "request_id": id.wireValue, "request": payload])
    }
    private func receive(_ line: String) {
        guard !failed, let data = line.data(using: .utf8),
              let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if !failed && !stopping { fail("Risposta non valida dal collegamento interattivo.") }; return
        }
        if agent == .codex { codex(frame) } else { claude(frame, line: line) }
    }

    private func codex(_ frame: [String: Any]) {
        if let method = frame["method"] as? String {
            let params = frame["params"] as? [String: Any] ?? [:]
            if let id = AgentRequestID.parse(frame["id"]) { codexPermission(id, method: method, params: params); return }
            guard params["threadId"] as? String == remoteID else { return }
            if method == "serverRequest/resolved", let id = AgentRequestID.parse(params["requestId"]) { expirePermission(id); return }
            if method == "turn/started", let turn = params["turn"] as? [String: Any], let id = turn["id"] as? String {
                if let remoteTurnID, remoteTurnID != id { fail("Codex ha avviato un turno inatteso."); return }
                remoteTurnID = id
            }
            if let id = params["turnId"] as? String, id != remoteTurnID { return }
            switch method {
            case "item/agentMessage/delta":
                let id = params["itemId"] as? String ?? "message"
                messageTexts[id, default: ""] += params["delta"] as? String ?? ""
                text = messageTexts[id] ?? ""; onEvent(.text(text))
            case "item/started", "item/completed":
                guard let item = params["item"] as? [String: Any] else { return }
                if let id = item["id"] as? String { items[id] = item }
                switch item["type"] as? String {
                case "agentMessage":
                    if let value = item["text"] as? String, !value.isEmpty { text = value; onEvent(.text(value)) }
                case "commandExecution": onEvent(.activity("Esegue \((item["command"] as? String ?? "comando").prefix(80))"))
                case "fileChange": onEvent(.activity("Modifica i file del progetto"))
                case "mcpToolCall": onEvent(.activity("Usa \(item["server"] as? String ?? "MCP"): \(item["tool"] as? String ?? "strumento")"))
                case "reasoning": onEvent(.activity("Sta ragionando…"))
                default: break
                }
            case "turn/completed":
                guard let turn = params["turn"] as? [String: Any], turn["id"] as? String == remoteTurnID else { return }
                let status = turn["status"] as? String
                let outcome: BackendTurnOutcome = status == "completed" ? .completed : status == "interrupted" ? (steeringRequested ? .interrupted : .cancelled) : .failed
                if outcome == .failed { text = (turn["error"] as? [String: Any])?["message"] as? String ?? "Turno Codex non riuscito." }
                endTurn(outcome)
            default: break
            }
            return
        }
        guard let id = AgentRequestID.parse(frame["id"]), let kind = requests.removeValue(forKey: id) else {
            if !stopping { fail("Risposta Codex senza richiesta corrispondente.") }; return
        }
        if let error = frame["error"] as? [String: Any] { fail(error["message"] as? String ?? "Richiesta Codex non riuscita."); return }
        guard let result = frame["result"] as? [String: Any] else { fail("Risposta Codex incompleta."); return }
        if stopping && kind != .interrupt { return }
        switch kind {
        case .initialize:
            send(["method": "initialized"])
            guard let request else { return }
            let backend = request.configuration.codex ?? CodexBackend(model: request.configuration.model ?? "")
            var params: [String: Any] = ["cwd": request.cwd, "modelProvider": backend.provider.rawValue,
                "approvalPolicy": request.configuration.permissionMode == .acceptEdits ? "on-request" : "never",
                "approvalsReviewer": "user", "sandbox": request.configuration.permissionMode == .acceptEdits ? "workspace-write" : "danger-full-access",
                "developerInstructions": Self.guidance(request.guidance)]
            if !backend.cleanModel.isEmpty { params["model"] = backend.cleanModel }
            if let resume = request.resume { params["threadId"] = resume }
            rpc(.thread, method: request.resume == nil ? "thread/start" : "thread/resume", params: params)
        case .thread:
            guard let thread = result["thread"] as? [String: Any], let id = thread["id"] as? String,
                  !id.isEmpty, let request, request.resume == nil || request.resume == id else { fail("Codex non ha ripreso il contesto richiesto."); return }
            remoteID = id; onEvent(.sessionID(id)); promptSent = true
            rpc(.prompt, method: "turn/start", params: ["threadId": id,
                "input": [["type": "text", "text": request.task, "text_elements": [] as [String]]]])
        case .prompt:
            guard let turn = result["turn"] as? [String: Any], let id = turn["id"] as? String,
                  remoteTurnID == nil || remoteTurnID == id else { fail("Codex non ha identificato il turno."); return }
            remoteTurnID = id
            // A late start response must not clear an interruption/close deadline.
            if !terminal && !steeringRequested { deadline?.cancel(); deadline = nil }
        case .interrupt: interruptAcknowledged = true; finishIfSettled()
        }
    }

    private func codexPermission(_ id: AgentRequestID, method: String, params: [String: Any]) {
        guard !terminal, !stopping, !steeringRequested, promptSent,
              params["threadId"] as? String == remoteID, params["turnId"] as? String == remoteTurnID else {
            send(["id": id.wireValue, "error": ["code": -32600, "message": "Richiesta fuori dal turno attivo"]]); return
        }
        guard !seenPermissionIDs.contains(id) else { fail("Identificativo di approvazione Codex ripetuto."); return }
        let title: String
        var options = [ApprovalOption(optionID: "deny", name: "Reject", kind: "reject_once")]
        switch method {
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
            title = method.contains("commandExecution") ? "Esecuzione di un comando" : "Modifica di file"
            let decisions = params["availableDecisions"] as? [Any]
            if decisions == nil || decisions!.contains(where: { $0 as? String == "accept" }) {
                options.append(ApprovalOption(optionID: "allow", name: "Allow once", kind: "allow_once"))
            }
        case "item/permissions/requestApproval":
            title = "Accesso aggiuntivo per il turno"
            guard params["permissions"] is [String: Any] else { fail("Richiesta di accesso Codex incompleta."); return }
            options.append(ApprovalOption(optionID: "allow", name: "Allow for this turn", kind: "allow_turn"))
        default:
            send(["id": id.wireValue, "error": ["code": -32601, "message": "Richiesta interattiva non supportata da Orbit"]])
            fail("Codex ha richiesto un'interazione non supportata da Orbit (\(method))."); return
        }
        publishPermission(id, method: method, params: params, title: title, options: options)
    }

    private func claude(_ frame: [String: Any], line: String) {
        switch frame["type"] as? String {
        case "control_response":
            guard let response = frame["response"] as? [String: Any], let id = AgentRequestID.parse(response["request_id"]),
                  let kind = requests.removeValue(forKey: id) else { fail("Risposta Claude senza richiesta corrispondente."); return }
            guard response["subtype"] as? String == "success" else { fail(response["error"] as? String ?? "Richiesta Claude non riuscita."); return }
            if stopping && kind != .interrupt { return }
            if kind == .initialize, let request, let remoteID {
                onEvent(.sessionID(remoteID)); deadline?.cancel(); deadline = nil; promptSent = true
                send(["type": "user", "session_id": remoteID, "parent_tool_use_id": NSNull(),
                    "message": ["role": "user", "content": request.task]])
            } else if kind == .interrupt { interruptAcknowledged = true; finishIfSettled() }
        case "control_request":
            guard let id = AgentRequestID.parse(frame["request_id"]), let payload = frame["request"] as? [String: Any] else { fail("Richiesta Claude incompleta."); return }
            guard !seenPermissionIDs.contains(id) else { fail("Identificativo di approvazione Claude ripetuto."); return }
            guard payload["subtype"] as? String == "can_use_tool" else {
                claudeError(id, message: "Interazione non supportata da Orbit")
                fail("Claude ha richiesto un'interazione non supportata da Orbit."); return
            }
            guard !terminal, !stopping, !steeringRequested, promptSent else { claudeDeny(id, message: "Turno interrotto"); return }
            guard let name = payload["tool_name"] as? String, payload["input"] is [String: Any] else { fail("Richiesta di permesso Claude incompleta."); return }
            publishPermission(id, method: "can_use_tool", params: payload,
                title: payload["title"] as? String ?? ClaudeStreamParser.italianVerb(name),
                options: [ApprovalOption(optionID: "deny", name: "Reject", kind: "reject_once"), ApprovalOption(optionID: "allow", name: "Allow once", kind: "allow_once")])
        case "control_cancel_request":
            if let id = AgentRequestID.parse(frame["request_id"]) { expirePermission(id) }
        case "result":
            guard promptSent, !terminal, frame["session_id"] as? String == remoteID else { fail("Risultato Claude fuori dalla sessione attiva."); return }
            text = frame["result"] as? String ?? (frame["errors"] as? [String])?.joined(separator: "\n") ?? ""
            let errors = (frame["errors"] as? [String]) ?? []
            // CLI versions report interruption as an error result. A successful
            // result that won the race also seals all tool work before resume.
            let success = frame["subtype"] as? String == "success" && frame["is_error"] as? Bool == false
            let interrupted = steeringRequested && (success || errors.contains { $0.lowercased().contains("interrupt") })
            endTurn(interrupted ? .interrupted : success ? .completed : .failed)
        default:
            // A subagent message must not replace the parent session's identity.
            if frame["parent_tool_use_id"] is String { return }
            for event in ClaudeStreamParser.parse(line: line) {
                if case .sessionID(let id) = event {
                    if id != remoteID { fail("Claude ha cambiato identificativo di sessione."); return }
                }
                if case .text(let value) = event { text = value }
                onEvent(event)
            }
        }
    }

    private func publishPermission(_ id: AgentRequestID, method: String, params: [String: Any], title: String, options: [ApprovalOption]) {
        guard let remoteID else { fail("Richiesta di permesso senza sessione."); return }
        seenPermissionIDs.insert(id)
        let approval = AgentApproval(requestID: id, remoteSessionID: remoteID,
            toolCallID: params["itemId"] as? String ?? params["tool_use_id"] as? String ?? "", title: title,
            details: approvalDetails(method: method, params: params), options: options)
        permissions[approval.id] = Permission(approval: approval, method: method, payload: params)
        onEvent(.approvalRequested(approval))
    }
    private func approvalDetails(method: String, params: [String: Any]) -> String {
        func json(_ value: Any) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else { return "" }
            return String(data: data, encoding: .utf8) ?? ""
        }
        var parts: [String] = []
        if let reason = params["reason"] as? String ?? params["description"] as? String { parts.append(reason) }
        if let command = params["command"] as? String { parts.append("Comando:\n" + command) }
        if let cwd = params["cwd"] as? String { parts.append("Directory: " + cwd) }
        if let root = params["grantRoot"] as? String { parts.append("Cartella interessata: " + root) }
        if let context = params["networkApprovalContext"] as? [String: Any] { parts.append("Accesso di rete:\n" + json(context)) }
        if let profile = params["permissions"] as? [String: Any] ?? params["additionalPermissions"] as? [String: Any] { parts.append("Permessi richiesti:\n" + json(profile)) }
        if let id = params["itemId"] as? String, let changes = items[id]?["changes"] as? [[String: Any]] {
            for change in changes {
                if let path = change["path"] as? String { parts.append("File: " + path) }
                if let diff = change["diff"] as? String { parts.append(diff) }
            }
        }
        if method == "can_use_tool", let input = params["input"] { parts.append("Operazione:\n" + json(input)) }
        return parts.isEmpty ? "La CLI richiede un permesso per questa operazione." : parts.joined(separator: "\n\n")
    }
    func resolveApproval(_ id: UUID, optionID: String) throws {
        guard !terminal, !stopping, !steeringRequested, let permission = permissions[id],
              permission.approval.options.contains(where: { $0.optionID == optionID && $0.isTransient }) else { throw AgentBackendError.expiredApproval }
        permissions[id] = nil
        let allow = optionID == "allow"
        if agent == .claude {
            let response: [String: Any] = allow ? ["behavior": "allow", "updatedInput": permission.payload["input"] ?? [:]] : ["behavior": "deny", "message": "Permesso rifiutato dall'utente in Orbit"]
            claudeResponse(permission.approval.requestID, response)
        } else if permission.method == "item/permissions/requestApproval" {
            send(["id": permission.approval.requestID.wireValue,
                "result": ["permissions": allow ? permission.payload["permissions"] ?? [:] : [:], "scope": "turn"]])
        } else {
            let available = permission.payload["availableDecisions"] as? [Any]
            let deny = available == nil || available!.contains(where: { $0 as? String == "decline" }) ? "decline" : "cancel"
            send(["id": permission.approval.requestID.wireValue, "result": ["decision": allow ? "accept" : deny]])
        }
    }
    private func claudeResponse(_ id: AgentRequestID, _ payload: [String: Any]) {
        send(["type": "control_response", "response": ["subtype": "success", "request_id": id.wireValue, "response": payload]])
    }
    private func claudeDeny(_ id: AgentRequestID, message: String) { claudeResponse(id, ["behavior": "deny", "message": message]) }
    private func claudeError(_ id: AgentRequestID, message: String) {
        send(["type": "control_response", "response": ["subtype": "error", "request_id": id.wireValue, "error": message]])
    }
    private func expirePermission(_ requestID: AgentRequestID) {
        for permission in Array(permissions.values) where permission.approval.requestID == requestID {
            permissions[permission.approval.id] = nil; onEvent(.approvalExpired(permission.approval.id))
        }
    }
    private func expirePermissions() {
        for permission in Array(permissions.values) { onEvent(.approvalExpired(permission.approval.id)) }
        permissions.removeAll()
    }
    private func endTurn(_ outcome: BackendTurnOutcome) {
        guard !terminal else { fail("Risultato terminale ripetuto."); return }
        terminal = true; terminalOutcome = outcome; expirePermissions()
        onEvent(.turnEnded(outcome))
        if outcome != .interrupted && !stopping { onEvent(.result(text: text, isError: outcome != .completed)) }
        finishIfSettled()
    }
    private func finishIfSettled() {
        guard terminal, !inputClosed else { return }
        if steeringRequested {
            guard interruptAcknowledged else { return }
            guard terminalOutcome == .interrupted else { fail("Interruzione non confermata: la nuova direzione resta in coda."); return }
        }
        inputClosed = true; process?.closeInput()
        armDeadline(seconds: 10, message: "\(agent.displayName) non ha concluso il processo: ripresa automatica sospesa.")
    }
    func interruptForSteering() throws {
        guard canSteer else { throw AgentBackendError.liveFollowupUnavailable }
        steeringRequested = true; expirePermissions(); interrupt()
        armDeadline(seconds: 10, message: "Interruzione non confermata: la nuova direzione resta in coda.")
    }
    private func interrupt() {
        if agent == .codex, let remoteID, let remoteTurnID {
            rpc(.interrupt, method: "turn/interrupt", params: ["threadId": remoteID, "turnId": remoteTurnID])
        } else if agent == .claude { control(.interrupt, payload: ["subtype": "interrupt"]) }
    }
    func sendFollowup(_ task: String) throws { throw AgentBackendError.liveFollowupUnavailable }
    func cancel() {
        if stopping { process?.kill(); return }
        stopping = true; expirePermissions()
        if promptSent && !terminal { interrupt() }
        else { inputClosed = true; process?.closeInput() }
        armDeadline(seconds: 3, message: nil)
    }
    func close() { stopping = true; deadline?.cancel(); expirePermissions(); process?.kill() }
    private func fail(_ message: String) {
        guard !failed else { return }
        failed = true; deadline?.cancel(); text = message; expirePermissions()
        if !stopping { onEvent(.turnEnded(.failed)); onEvent(.result(text: message, isError: true)) }
        process?.kill()
    }
    private func armDeadline(seconds: Int, message: String?) {
        deadline?.cancel()
        deadline = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            if let message { self?.fail(message) } else { self?.process?.kill() }
        }
    }
}
