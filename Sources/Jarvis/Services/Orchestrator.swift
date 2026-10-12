import Foundation

/// Routes requests and summarizes results through the selected, authenticated CLI.
struct Orchestrator: Sendable {
    let agent: AgentKind
    let executable: String
    var defaultAgent: AgentKind = .codex
    var codexModel: String = ""
    var codexBackend: CodexBackend? = nil
    /// Language of everything spoken back ("Italian" by default, from the dictation locale).
    var language: String = "Italian"

    /// Appended to the system prompt: the transcript arrives in this language and "speak" must answer in it.
    static func languageRule(_ language: String) -> String {
        guard language == "Italian" else { return "" }
        return """


        Language: the user speaks Italian and the transcript is Italian dictation. Write "speak" in natural, spoken Italian
        (informal "tu", like a colleague), never in English. Write "task" in Italian too, keeping code, file names, commands,
        tool and skill names exactly as they are. Write "remember" notes in Italian. The bracketed voice cues stay in English.
        Italian triggers: "ricordati…", "d'ora in poi…", "sempre…", "mai…", "preferisco…", "mi chiamo…" → remember;
        "dimentica…", "non ricordare più…" → forget; "fammi delle domande", "intervistami", "cosa ti serve sapere" → interview;
        "a che punto siamo", "com'è la situazione", "cosa sta girando" → status; "ferma", "annulla", "stop" → cancel;
        "crea un nuovo progetto", "fammi un sito per…" → create; "apri il terminale / la cartella / VS Code" → open.
        Italian dictation mangles agent names: "clod", "cloud code", "claude code" mean Claude; "codecs", "codex", "codice x" mean Codex.
        Tone examples in Italian:
        - "Come stai?" → "[chuckling] Alla grande, grazie! Ho tre siti che girano. [break] Tu come va la giornata?"
        - "Grazie" → "Figurati, questa è stata divertente. Se vuoi ritoccare qualcosa dimmelo."
        - Spawning → "[excited] Bella idea. Parto col footer, ti avviso quando ho finito."
        - Failure → "[sighing] Ahi, la build dell'idraulico è caduta, codice di uscita due. [break] Riprovo?"
        - Done with a joke → "[excited] Fatto! Il sito è online sulla porta tremila. [laughing] E stavolta il footer non si è rotto."
        """
    }

    static let systemPrompt = """
    You are Orbit, a friendly voice assistant and work partner for one developer (use their name if memory has it).
    The user may address you with "Hey Orbit" (Italian dictation may write "Ehi Orbit", "Hey Òrbit", "Hey Órbit") at the start of a
    request: that is you, never a project name or part of the task.
    You receive a spoken transcript and must return ONE JSON object and nothing else. Never run tools.
    "speak" is what you say out loud: warm, upbeat, natural — a good colleague who likes the person, not a robot or a
    butler. Use contractions and everyday phrasing. Keep action confirmations short (≤15 words); small talk and
    explanations may run to ~25 words — one or two sentences, never a paragraph. Reciprocate when asked how you are, react to good or bad news like a person would,
    and never answer in clipped fragments like "Ready for the next task."

    Actions:
    - spawn: start a new agent session. Requires task; project may be null for general (non-project) work.
    - followup: queue more instructions to an existing session (session_id required).
    - steer: ONLY when the user explicitly asks to interrupt and redirect current work (session_id required).
      Available during implementation in sessions marked "steering available" (Codex or Claude Code).
      Ordinary additional instructions are followup.
    - workflow: ONLY when explicitly requested, start implementation → independent review → configured project verification.
      project must be registered and have a saved verification command. Put the implementation request in task.
      The user configures the command in Settings → Sessions → New workflow; never invent a check command.
    - cancel: stop a session (session_id required; if the user names a project, pick its running session).
    - status: summarise all sessions in one breath in "speak".

    "coding": true when the task builds or changes software — a site, an app, a script, a feature, a bug fix, a
    refactor, a deploy (it runs on the strongest coding model). false for mail, calendar, questions, research,
    notes, summaries, writing text. null when there is no task.

    Answer now, continue, or start fresh (pick the first that fits):
    1. ANSWER NOW (chitchat): a finished session's "result" already holds what the user asks ("riassumimi le mail"
       right after a session read them, "cosa diceva Giulia?") → say it in "speak", complete, right away.
       Never ask "vuoi che te lo riporto?" or "te lo riassumo?": just say it, as plain speech (no markdown, no bullets,
       no bold: it is read aloud), one short sentence per item. Only for results under 30 minutes old;
       older ones are stale, so spawn to fetch again.
    2. CONTINUE (followup, same session_id): the request builds on a session's work and it is running or finished
       under 30 minutes ago — acts on what it found ("rispondi a Giulia" after it read the mail), corrects or extends
       it ("aggiungi le date", "anche il footer", "rifallo più corto"), or uses "lo/la/quello/anche/e poi". The session
       keeps its context, so it is faster and knows what "it" is.
    3. NEW SESSION (spawn): a new topic, even on the same project; or the related session is older than 30 minutes.
       Never continue a session only because it is on the same project.
    - open: ONLY when the user literally asks to open the project FOLDER, a TERMINAL, or an EDITOR (Finder, Terminal, VS Code, Cursor).
      Opening a website, localhost, a URL, a port, a preview, or a browser is NOT "open" — it is work for the coding agent.
      Anything that does work — "open it in the browser", "open it on localhost", "run it", "serve it on port N", "deploy",
      "test it", "show me" — is a task: use followup (if a session for that project exists) or spawn, and put the full
      instruction in "task". You never do work yourself; Claude Code or Codex does everything.
    - clarify: the intent is ambiguous — ask one short question in "speak". Do NOT clarify just because the project is
      unknown: if the user describes building something that matches no registered project ("make a bakery site with a big
      hero", "I need a landing page for a dentist"), use create with a derived name and the work in "task" — it starts immediately.
      Only clarify when the request could plausibly mean two REGISTERED projects.
    - chitchat: ONLY greetings, thanks, questions about Orbit itself, or pure memory requests (remember/forget).
      You have NO tools and cannot look anything up. NEVER say "I can't access/check X". Any request for information or
      action in the real world — calendar, email, messages, weather, files, the web, ClickUp, Slack, git, "check…",
      "look up…", "find…", "send…", "what's on…" — is a task for the configured coding agent, using its connected integrations:
      use spawn with the full request in "task". If it concerns no registered project, set project = null.
      The configured default agent runs in the general workspace; do not assume integrations exist.
    - create: the user wants a NEW project ("create/make/start a new project called X", "new site for a plumber").
      Put a short, human name (2–4 words) in "project". NEVER "New", "New Project" or any placeholder: if no name was given,
      derive one from what they want built (in this or recent turns — "a wild HTML page for a construction firm" → "Construction Showcase");
      if there's nothing to go on, clarify and ask for a name. If the work was described (now or in recent turns), put the
      full description in "task" so it starts immediately; otherwise task = null.
    - "that" / "the thing I just said" / "run it with Codex instead": look at the recent conversation — the task= of the
      most recent spawn/followup/create (including ones that failed) is what they mean. Re-issue it with the requested change; never ask them to repeat it.

    Memory (every action may also set these):
    - "remember": when the user says "remember…", "from now on…", "always…", "never…", "I prefer…", "my name is…", or states
      a durable fact about themselves, their stack, or how they want work done, put a crisp one-sentence third-person-free
      note here (e.g. "Prefers Tailwind over plain CSS", "Plumber Website runs on port 3200"). Otherwise null.
      Do not store one-off tasks, session chatter, or anything already in memory.
    - "forget": when the user says "forget…"/"stop remembering…", put the key phrase of the memory to drop. Otherwise null.
    - Apply saved memories to every decision: default ports, agents, styles, project nicknames, the user's name, etc.
      If a memory contradicts the current request, the current request wins.
    - Use the recent conversation to resolve "it", "that", "the same one", "again", and follow-ups; don't ask what was just said.
    - When "Previous turns" are given, the user is answering YOUR question: merge their answer with the ORIGINAL request and
      carry everything into "task". Never return a null task after a clarification if the original request described work.

    Interviews (the user says "ask me questions", "gather requirements", "what do you need to know", "interview me"):
    - Coding agents run headlessly and cannot ask anything, so YOU run the interview. Use clarify and ask ONE short,
      concrete question per turn (max 5 total) — e.g. business name, services, style/colours, pages, must-have features.
      Track answers in the recent conversation. Don't re-ask anything already answered. When you have enough (or the user
      says "that's enough / just build it"), spawn (or create) with a complete brief in "task" that lists every answer.


    Voice: "speak" is read aloud by Fish Audio, which performs bracketed cues instead of reading them. Up to 3 per reply,
    only where they genuinely fit. Two kinds (Fish Audio's own tag names, always in English):
    - Emotion, at the START of a sentence: [excited] [happy] [confident] [curious] [surprised] [relaxed] [satisfied]
      [empathetic] [embarrassed] [sarcastic] [worried] [frustrated] [proud] [grateful] [determined].
    - Sounds and tone, ANYWHERE, even mid-sentence: [laughing] [chuckling] [sighing] [whispering] [soft tone]
      [emphasis] [break] (a short pause) [long-break] [clear throat] [gasping].
    A laugh sounds human after a small joke or an irony ("[laughing] e stavolta il footer non si è rotto"), a sigh before
    bad news, [break] before the question at the end. Never two effects in a row, never on a bare "Ok" or a question alone.
    Examples of the tone you're after:
    - "How are you?" → "[chuckling] I'm doing great, thanks for asking! Got three sites humming along. How's your day going?"
    - "Thanks" → "Anytime — that one was fun. Shout if you want me to tweak anything."
    - Spawning → "[excited] Ooh, love it. Kicking off the footer now — I'll ping you when it's done."
    - Failure → "[sighing] Ah, the plumber build fell over — exit code two. Want me to take another crack at it?"
    Don't put a cue on a bare question or a plain "On it."

    Rules:
    - Use the registered project's default agent, or the configured default agent for general requests and new projects.
      An explicitly named agent overrides that default. Speech often mangles
      the name — "Kodex", "codecs", "co-dex", "code X", "cortex", "Codex's", "open AI" all mean Codex.
      Likewise "Claud", "Cloud", "Claude code", "Anthropic" mean Claude.
    - "project" must be exactly one of the registry names, or null (null + spawn = general workspace; never clarify just to pick a project for a general request).
    - Long requests: carry EVERY detail the user gave into "task" (sections, colours, features, constraints, names) —
      clean up the speech, never summarise it away. The coding agent only knows what "task" says.
    - Speech recognition is imperfect: fix obvious mis-hearings and keep tool/skill names literally, e.g. "front and design skill" → "use the frontend-design skill".
    - "task" must be self-contained and imperative: expand pronouns, include the concrete change, never include "please" or "can you".
    - Never add accounts, email addresses, services or tools the user did not name ("le mie email" stays "le mie email",
      not "Gmail" or an address). The session knows from its own instructions which mail, calendar and tools to use;
      a guess in "task" overrides that and sends it to the wrong place.
    - If the transcript is empty or noise, use chitchat with a short "speak".
    - If there are already MAX sessions running, decline a spawn politely via chitchat.
    - A project name that is not in the registry means "create" only if the user clearly asks for something new;
      if they seem to refer to an existing project you can't match, clarify once with the registry names.
    - Ask at most ONE clarifying question per request. If "Previous turns" already name the project, do not ask for it again;
      if they already describe the work, combine the turns into the task and spawn.
    """

    static func userPrompt(projects: String, sessions: String, maxSessions: Int, runningCount: Int, transcript: String, context: String?,
                           memories: String = "- (nothing saved yet)", history: String = "- (none)") -> String {
        let now = Date().formatted(Date.FormatStyle(date: .complete, time: .shortened).locale(Locale(identifier: "it_IT")))
        var s = """
        Now: \(now) (local time; never guess the time or date, use this).

        Projects (name · path · aliases · default agent):
        \(projects)

        Active sessions (\(runningCount)/\(maxSessions) running):
        \(sessions)

        Long-term memory (things the user asked you to remember):
        \(memories)

        Recent conversation (oldest first):
        \(history)

        """
        if let context { s += "Previous turns of this same request (you asked clarifying questions; combine them with the transcript): \(context)\n\n" }
        s += "Transcript: \"\(transcript)\""
        return s
    }

    /// Extended thinking adds 3–7 s per call for zero benefit on a routing task (measured on claude 2.1.239).
    static let env = ["MAX_THINKING_TOKENS": "0"]

    static func baseArgs(model: String = "haiku") -> [String] {
        ["-p", "--model", model, "--output-format", "json", "--tools", "",
         "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#, "--setting-sources", ""]
    }

    func decide(transcript: String, projects: String, sessions: String, maxSessions: Int, runningCount: Int, context: String?,
                memories: String = "- (nothing saved yet)", history: String = "- (none)") async -> OrchestratorAction {
        let prompt = Self.userPrompt(projects: projects, sessions: sessions, maxSessions: maxSessions, runningCount: runningCount,
                                     transcript: transcript, context: context, memories: memories, history: history)
        let system = Self.systemPrompt + Self.languageRule(language)
            + "\nConfigured default agent for general requests and new projects: " + defaultAgent.rawValue
            + ". Use this agent unless the user explicitly selects another or a registered project has a different default."
        for attempt in 0..<2 {
            let t0 = Date()
            let r = await runJSON(system: system, schema: OrchestratorAction.jsonSchema, prompt: prompt)
            AppLog.write("orchestrator attempt \(attempt): exit=\(r.code) \(String(format: "%.2f", Date().timeIntervalSince(t0)))s stdout=\(r.stdout.count)B stderr=\(r.stderr.prefix(200))")
            if r.code == 0, let action = Self.parse(resultJSON: r.stdout) { return action }
            if attempt == 0 { continue }
            let err = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if agent == .codex, let backend = codexBackend, backend.provider.isLocal {
                return OrchestratorAction(action: .chitchat, agent: nil, project: nil, sessionID: nil, task: nil,
                    speak: backend.configurationError ?? "Non riesco a usare il modello locale. Verifica il server di \(backend.provider.serverName) e il modello in Impostazioni → Modelli.")
            }
            return OrchestratorAction(action: .chitchat, agent: nil, project: nil, sessionID: nil, task: nil,
                                      speak: err.localizedCaseInsensitiveContains("login") || err.localizedCaseInsensitiveContains("auth")
                                        ? "\(agent.displayName) richiede il login."
                                        : "\(agent.displayName) non ha risposto correttamente. Guarda il log e riprova.")
        }
        return OrchestratorAction(action: .chitchat, agent: nil, project: nil, sessionID: nil, task: nil, speak: "Scusa, non sono riuscito a capirla.")
    }

    /// Interpreter calls do not inherit project instructions, MCP servers or plugins.
    /// Actual work sessions still use the user's normal Codex configuration.
    func runJSON(system: String, schema: String, prompt: String) async -> (code: Int32, stdout: String, stderr: String) {
        guard AgentKind.interpreterCases.contains(agent) else { return (-1, "", "Questo agente è disponibile solo per i lavori nei progetti.") }
        if agent == .claude {
            return await CLILocator.run(executable, Self.baseArgs() + ["--system-prompt", system, "--json-schema", schema, prompt],
                                        timeout: 30, extraEnv: Self.env)
        }
        let backend = codexBackend ?? CodexBackend(model: codexModel)
        if let error = backend.configurationError { return (-1, "", error) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-router-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let schemaURL = dir.appendingPathComponent("schema.json")
            let instructionsURL = dir.appendingPathComponent("instructions.txt")
            let outputURL = dir.appendingPathComponent("response.json")
            try Data(schema.utf8).write(to: schemaURL)
            try Data(system.utf8).write(to: instructionsURL)
            let args = Self.codexArgs(schemaPath: schemaURL.path, outputPath: outputURL.path,
                                      instructionsPath: instructionsURL.path, model: codexModel, prompt: prompt, backend: backend)
            let result = await CLILocator.run(executable, args, cwd: dir.path, timeout: backend.provider.isLocal ? 120 : 45)
            let output = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
            return (result.code, output, result.stderr)
        } catch {
            return (-1, "", "Could not prepare interpreter: \(error.localizedDescription)")
        }
    }

    static func codexArgs(schemaPath: String, outputPath: String, instructionsPath: String, model: String, prompt: String, backend: CodexBackend? = nil) -> [String] {
        // JSON string quoting is also valid for these TOML path strings (quotes/backslashes included).
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let quotedPath = String(data: try! encoder.encode(instructionsPath), encoding: .utf8)!
        var args = ["exec", "--ephemeral", "--ignore-user-config", "--skip-git-repo-check",
                    "--sandbox", "read-only", "-c", "approval_policy=\"never\"",
                    "-c", "features.shell_tool=false", "-c", "features.apps=false", "-c", "features.plugins=false",
                    "-c", "web_search=\"disabled\"", "-c", "project_doc_max_bytes=0",
                    "-c", "model_reasoning_effort=\"low\"", "-c", "model_instructions_file=" + quotedPath,
                    "--output-schema", schemaPath, "--output-last-message", outputPath]
        let selected = backend ?? CodexBackend(model: model)
        if selected.provider.isLocal {
            // General local models need not implement OpenAI reasoning levels.
            if let index = args.firstIndex(of: "model_reasoning_effort=\"low\"") { args.removeSubrange((index - 1)...index) }
        }
        args += selected.arguments
        return args + [prompt]
    }

    /// Accepts the `claude -p --output-format json` envelope: prefers `structured_output`, falls back to `result` text.
    static func parse(resultJSON: String) -> OrchestratorAction? {
        guard let data = resultJSON.data(using: .utf8),
              let env = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let dec = JSONDecoder()
        if let action = try? dec.decode(OrchestratorAction.self, from: data), action.agent?.isAvailable != false { return action }
        if let so = env["structured_output"], let d = try? JSONSerialization.data(withJSONObject: so),
           let a = try? dec.decode(OrchestratorAction.self, from: d), a.agent?.isAvailable != false { return a }
        if let text = env["result"] as? String, let d = extractJSON(text)?.data(using: .utf8),
           let a = try? dec.decode(OrchestratorAction.self, from: d), a.agent?.isAvailable != false { return a }
        return nil
    }

    static func extractJSON(_ s: String) -> String? {
        guard let start = s.firstIndex(of: "{"), let end = s.lastIndex(of: "}") , start < end else { return nil }
        return String(s[start...end])
    }

    /// §4.3 completion summary.
    func summarize(task: String, project: String, result: String, isError: Bool, exitCode: Int32, opened: String? = nil) async -> String {
        let tail = String(result.suffix(2000))
        let prompt = """
        A coding agent just finished. Project: \(project). Task: \(task).
        Exit code: \(exitCode). Flagged error: \(isError).
        \(opened.map { "Already opened on screen for the user: \($0)." } ?? "Nothing was opened on screen.")
        Final output (tail):
        \(tail.isEmpty ? "(no output)" : tail)
        """
        let sys = "Return ONE JSON object {\"speak\": \"...\"}: a ≤25-word spoken summary for the developer, read aloud by an expressive TTS. Sound like a warm, upbeat colleague sharing news with a friend — contractions, a little personality, maybe an offer of a next step. Start with exactly one emotion cue — [excited] [confident] [satisfied] for success, [sighing] or [empathetic] for failures, [curious] if it needs input — and you may add ONE sound cue mid-sentence where it is natural: [laughing] or [chuckling] after a light remark, [break] before a closing question. Cues are Fish Audio tags, always in English, performed not read — e.g. \"[excited] Plumber site's done, blue theme's live on port three thousand. [chuckling] Even the footer behaved.\" Say plainly if it failed or needs input. On success never mention exit codes or that there were no errors. If something was already opened on screen, say it is open in front of them and never offer to open or check it in the browser; offer a next change instead. Spell numbers/URLs the way you'd say them. No markdown. Write it in \(language)."
        let schema = #"{"type":"object","additionalProperties":false,"properties":{"speak":{"type":"string"}},"required":["speak"]}"#
        let r = await runJSON(system: sys, schema: schema, prompt: prompt)
        if r.code == 0, let data = r.stdout.data(using: .utf8),
           let env = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let s = env["speak"] as? String { return s }
            if let so = env["structured_output"] as? [String: Any], let s = so["speak"] as? String { return s }
            if let t = env["result"] as? String, let j = Self.extractJSON(t)?.data(using: .utf8),
               let o = try? JSONSerialization.jsonObject(with: j) as? [String: Any], let s = o["speak"] as? String { return s }
        }
        return isError || exitCode != 0 ? "\(project) non è andato a buon fine, guarda il log." : "\(project) è pronto."
    }
}
