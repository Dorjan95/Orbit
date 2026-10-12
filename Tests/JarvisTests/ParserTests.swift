import XCTest
@testable import Jarvis

final class ParserTests: XCTestCase {
    private func fixture(_ name: String) throws -> String {
        let url = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testClaudeStreamFixture() throws {
        let events = try fixture("claude-stream.ndjson").split(separator: "\n").flatMap { ClaudeStreamParser.parse(line: String($0)) }
        XCTAssertTrue(events.contains(.sessionID("9e420cbc-12de-4457-b50b-67e7c18c3af5")))
        XCTAssertTrue(events.contains(.activity("Scrive Projects/website/hello.txt")))
        XCTAssertTrue(events.contains(.activity("Writing hello.txt")))
        XCTAssertTrue(events.contains(.text("Done.")))
        XCTAssertTrue(events.contains(.result(text: "Done.", isError: false)))
        XCTAssertFalse(events.contains(.needsInput))
    }

    func testCodexStreamFixture() throws {
        let events = try fixture("codex-stream.ndjson").split(separator: "\n").flatMap { CodexStreamParser.parse(line: String($0)) }
        XCTAssertTrue(events.contains(.sessionID("01a02d7f-1dcf-7842-a741-d4ffadca1a1a")))
        XCTAssertTrue(events.contains(.activity("Modifica website/bye.txt")))
        XCTAssertTrue(events.contains(.text("Creating `bye.txt` with the requested content.")))
        XCTAssertEqual(events.last, .result(text: "", isError: false))
    }

    func testGarbageLinesIgnored() {
        XCTAssertTrue(ClaudeStreamParser.parse(line: "not json").isEmpty)
        XCTAssertTrue(CodexStreamParser.parse(line: "Reading additional input from stdin...").isEmpty)
    }
}

final class OrchestratorTests: XCTestCase {
    func testParsesStructuredOutputEnvelope() throws {
        let url = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appendingPathComponent("orchestrator-result.json")
        let json = try String(contentsOf: url, encoding: .utf8)
        // Real envelope captured from claude 2.1.239 (2-field schema); missing optional keys decode as nil.
        let a = Orchestrator.parse(resultJSON: json)
        XCTAssertEqual(a?.action, .status); XCTAssertNil(a?.project); XCTAssertFalse(a?.speak.isEmpty ?? true)
    }

    func testParsesFullContract() {
        let env = #"{"type":"result","result":"{\"action\":\"spawn\",\"agent\":\"claude\",\"project\":\"website\",\"session_id\":null,\"task\":\"Change the hero headline to 'Build faster with AI' and deploy\",\"speak\":\"On it.\"}","structured_output":{"action":"spawn","agent":"claude","project":"website","session_id":null,"task":"Change the hero headline to 'Build faster with AI' and deploy","speak":"On it."}}"#
        let a = Orchestrator.parse(resultJSON: env)
        XCTAssertEqual(a?.action, .spawn)
        XCTAssertEqual(a?.agent, .claude)
        XCTAssertEqual(a?.project, "website")
        XCTAssertNil(a?.sessionID)
        XCTAssertEqual(a?.speak, "On it.")
    }

    func testFallsBackToResultTextWithProse() {
        let env = #"{"type":"result","result":"Sure! {\"action\":\"status\",\"agent\":null,\"project\":null,\"session_id\":null,\"task\":null,\"speak\":\"Nothing running.\"}"}"#
        XCTAssertEqual(Orchestrator.parse(resultJSON: env)?.action, .status)
    }

    func testArgsNeverContainAPIKeys() {
        let args = Orchestrator.baseArgs().joined(separator: " ")
        XCTAssertFalse(args.contains("api-key")); XCTAssertTrue(args.contains("--tools "))
        XCTAssertNil(CLILocator.childEnvironment["ANTHROPIC_API_KEY"])
        XCTAssertNil(CLILocator.childEnvironment["OPENAI_API_KEY"])
    }

    func testRunnerArguments() {
        let start = AgentRunner.arguments(agent: .codex, task: "t", mode: .acceptEdits, resume: nil)
        XCTAssertEqual(start.first, "exec")
        XCTAssertTrue(start.contains("--json"))
        let resume = AgentRunner.arguments(agent: .codex, task: "t", mode: .acceptEdits, resume: "abc")
        XCTAssertLessThan(resume.firstIndex(of: "-s")!, resume.firstIndex(of: "resume")!)
        XCTAssertEqual(resume[resume.firstIndex(of: "resume")! + 1], "abc")
        XCTAssertTrue(AgentRunner.arguments(agent: .codex, task: "t", mode: .bypassPermissions, resume: nil).contains("--dangerously-bypass-approvals-and-sandbox"))
        let c = AgentRunner.arguments(agent: .claude, task: "t", mode: .acceptEdits, resume: "sid")
        XCTAssertTrue(c.contains("--resume")); XCTAssertTrue(c.contains("acceptEdits")); XCTAssertTrue(c.contains("stream-json"))
    }
}

@MainActor
final class StoreTests: XCTestCase {
    func testRegistryResolution() {
        let r = ProjectRegistry()
        r.projects = [Project(name: "website", path: "~/Projects/website", aliases: ["the site", "homepage"]),
                      Project(name: "api", path: "~/Projects/api")]
        XCTAssertEqual(r.resolve("Website")?.name, "website")
        XCTAssertEqual(r.resolve("the site")?.name, "website")
        XCTAssertEqual(r.resolve("API project")?.name, "api")
        XCTAssertNil(r.resolve(nil)); XCTAssertNil(r.resolve("unknown"))
    }

    func testProgressSpeechNeverReadsCommandsOrPaths() {
        XCTAssertEqual(ProgressSpeech.phrase(forActivity: "Modifica src/components/Hero.tsx"), "sto modificando Hero.tsx")
        XCTAssertEqual(ProgressSpeech.phrase(forActivity: "Esegue npm run build && npm test"), "sto lanciando un comando")
        XCTAssertEqual(ProgressSpeech.phrase(forActivity: "Cerca TODO|FIXME"), "sto cercando nel codice")
        XCTAssertNil(ProgressSpeech.phrase(forActivity: ""))
        XCTAssertEqual(ProgressSpeech.narration(from: "Ora controllo i test della **home**."), "Ora controllo i test della home.")
        XCTAssertNil(ProgressSpeech.narration(from: "Fatto:\n- a\n- b"))
        XCTAssertNil(ProgressSpeech.narration(from: "```swift\nlet x = 1\n```"))
    }

    func testWakeWordCommand() {
        XCTAssertEqual(WakeService.commandAfterWakeWord(in: "Hey Orbit, apri Prisma nel terminale"), "apri Prisma nel terminale")
        XCTAssertEqual(WakeService.commandAfterWakeWord(in: "stavo dicendo che ehi Òrbit a che punto sei"), "a che punto sei")
        XCTAssertEqual(WakeService.commandAfterWakeWord(in: "Hey Orbit"), "")
        XCTAssertEqual(WakeService.commandAfterWakeWord(in: "HEY, ORBIT! avvia Demo"), "avvia Demo")
        XCTAssertEqual(WakeService.commandAfterWakeWord(in: "Ehi Órbit, apri il sito"), "apri il sito")
        XCTAssertEqual(WakeService.commandAfterWakeWord(in: "hey\nOrbit apri"), "apri")
        for text in ["Orbit", "Orbit apri il sito", "ORBIT! avvia Demo", "Òrbit", "Hey", "heyorbit", "they orbit", "Ehi", "ehiorbita", "Hey orbita", "hey orbital", "hey orbitale", "hey unorbit", "Hey Jarvis apri il sito", "Giarvis", "ho parlato con Travis ieri", "apri il sito", "hey apri il progetto Orbit"] {
            XCTAssertNil(WakeService.commandAfterWakeWord(in: text), text)
        }
        // A pause after the wake phrase may restart the transcript without it.
        XCTAssertEqual(WakeService.strip("a che punto sei"), "a che punto sei")
        XCTAssertEqual(WakeService.strip("Hey Orbit apri"), "apri")
        XCTAssertEqual(WakeService.strip("ok Hey Orbit apri"), "apri")
        XCTAssertEqual(WakeService.strip("Orbit apri"), "Orbit apri")
        // Mentioning the app or product inside a command must preserve the task.
        XCTAssertEqual(WakeService.strip("voglio che mi crei un sito web del nostro nuovo prodotto ossia Orbit"),
                       "voglio che mi crei un sito web del nostro nuovo prodotto ossia Orbit")
        XCTAssertEqual(WakeService.strip("Hey Orbit crea un sito sul prodotto Orbit"), "crea un sito sul prodotto Orbit")
        XCTAssertEqual(WakeService.commandAfterWakeWord(in: "Hey Orbit crea un sito sul prodotto Orbit"), "crea un sito sul prodotto Orbit")
        XCTAssertEqual(WakeService.commandAfterWakeWord(in: "hey orbit apri, hey orbit chiudi"), "chiudi")
        XCTAssertEqual(WakeService.strip("allora senti un attimo Hey Orbit apri Prisma", within: WakeService.wordsBeforeLastName(in: "allora senti un attimo Hey Orbit") + 1), "apri Prisma")
        XCTAssertEqual(WakeService.wordsBeforeLastName(in: "allora senti Hey Orbit"), 2)
        XCTAssertTrue(WakeService.isRestart(from: "Hey Orbit apri", to: "il sito"))
        XCTAssertFalse(WakeService.isRestart(from: "Hey Orbit apri", to: "Hey Orbit apri il sito"))
        XCTAssertFalse(WakeService.isRestart(from: "Hey Orbit apri il", to: "Hey Orbit apri i"))
        XCTAssertFalse(WakeService.isRealInterruption("Orbit"))
        XCTAssertTrue(WakeService.isRealInterruption("Hey Orbit"))
    }

    func testClapDetector() {
        let sr = 48_000.0
        var rng = SystemRandomNumberGenerator()
        func noise(_ secs: Double, _ amp: Float) -> [Float] { (0..<Int(secs * sr)).map { _ in Float.random(in: -amp...amp, using: &rng) } }
        func clap() -> [Float] { (0..<Int(0.06 * sr)).map { i in Float.random(in: -0.7...0.7, using: &rng) * exp(-Float(i) / Float(0.008 * sr)) } }
        func run(_ parts: [[Float]]) -> Int {
            var d = ClapDetector(sampleRate: sr); var n = 0
            for p in parts { var k = 0; while k < p.count { let e = min(k + 1024, p.count); if d.process(p[k..<e]) { n += 1 }; k = e } }
            return n
        }
        let room = noise(0.5, 0.004)
        XCTAssertEqual(run([room, clap(), noise(0.25, 0.004), clap(), room]), 1, "two claps 0.3 s apart")
        XCTAssertEqual(run([room, clap(), room, room]), 0, "one clap")
        XCTAssertEqual(run([room, clap(), noise(1.0, 0.004), clap(), room]), 0, "claps a second apart")
        XCTAssertEqual(run([room, noise(1.0, 0.3), room]), 0, "sustained loud sound")
        // Speech-like: loud bursts that last 150 ms each, not short bangs.
        XCTAssertEqual(run([room, noise(0.15, 0.25), noise(0.1, 0.004), noise(0.15, 0.25), room]), 0, "syllables")
        XCTAssertEqual(run([room, clap(), noise(0.25, 0.004), clap(), noise(0.3, 0.004), clap(), noise(0.25, 0.004), clap(), room]), 1, "refractory after a double clap")
    }

    func testTaskNeverNamesAMailboxTheUserDidNotSay() {
        XCTAssertEqual(Coordinator.stripUnsaidMail("Leggi le ultime tre email ricevute su mario.rossi@gmail.com e riassumimi il contenuto.", transcript: "mi riassumi le ultime tre email"),
                       "Leggi le ultime tre email ricevute e riassumimi il contenuto.")
        XCTAssertEqual(Coordinator.stripUnsaidMail("Controlla le email su Gmail di oggi", transcript: "controlla le email di oggi"), "Controlla le email di oggi")
        XCTAssertEqual(Coordinator.stripUnsaidMail("Controlla Gmail", transcript: "controlla gmail"), "Controlla Gmail")
        XCTAssertEqual(Coordinator.stripUnsaidMail("Scrivi a sun@fish.audio", transcript: "scrivi a sun@fish.audio"), "Scrivi a sun@fish.audio")
    }

    func testSessionResultToOpen() {
        func tool(_ name: String, _ input: String) -> String { #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":""# + name + #"","input":"# + input + "}]}}" }
        let wrote = tool("Write", #"{"file_path":"/tmp/p/index.html","content":"x"}"#)
        XCTAssertEqual(SessionResult.viewable(ndjson: wrote, resultText: "Fatto")?.path, "/tmp/p/index.html")
        XCTAssertEqual(SessionResult.viewable(ndjson: wrote, resultText: "Gira su http://localhost:5173/ ora")?.absoluteString, "http://localhost:5173/")
        XCTAssertNil(SessionResult.viewable(ndjson: wrote + "\n" + tool("Bash", #"{"command":"open index.html"}"#), resultText: ""))
        XCTAssertNil(SessionResult.viewable(ndjson: tool("Edit", #"{"file_path":"/tmp/p/app.swift"}"#), resultText: "Fatto"))
    }

    func testCodingTasksRunOnTheCodingModel() {
        XCTAssertEqual(AgentRunner.arguments(agent: .claude, task: "t", mode: .bypassPermissions, resume: nil, model: "claude-opus-5-5").suffix(2), ["--model", "claude-opus-5-5"])
        XCTAssertFalse(AgentRunner.arguments(agent: .claude, task: "t", mode: .bypassPermissions, resume: nil).contains("--model"))
        let a = try? JSONDecoder().decode(OrchestratorAction.self, from: Data(#"{"action":"spawn","agent":null,"project":null,"session_id":null,"task":"fai il sito","speak":"ok","remember":null,"forget":null,"coding":true}"#.utf8))
        XCTAssertEqual(a?.coding, true)
    }

    func testTalkOverFindsTheUsersWords() {
        let said = "C'era una volta un gatto arancione di nome Micio che viveva in un piccolo appartamento a Milano."
        // Jarvis's own words coming back through the mic, even slightly misheard: nothing new.
        XCTAssertEqual(WakeService.novelTail(heard: "c'era una volta un gatto arancione di nome micio", spoken: said), [])
        XCTAssertEqual(WakeService.novelTail(heard: "un gatto arancioni di nome Miciò che viveva", spoken: said), [])
        // The user talking over it.
        XCTAssertEqual(WakeService.novelTail(heard: "un gatto arancione di nome aspetta fermati", spoken: said), ["aspetta", "fermati"])
        XCTAssertEqual(WakeService.novelTail(heard: "viveva in un piccolo basta così grazie", spoken: said), ["basta", "cosi", "grazie"])
        // Both talking at once: the recognizer interleaves the voices.
        XCTAssertEqual(WakeService.novelTail(heard: "gatto aspetta arancione fermati", spoken: said), ["aspetta", "fermati"])
        // Jarvis's own voice misheard into short fragments is not the user (29/09: "cad pro", "pre sehr").
        let mail = "Tre email: Rossi Srl propone fondi europei, Giulia chiede del Mastermind."
        XCTAssertLessThan(WakeService.novelTail(heard: "tre email cad pro fondi europei", spoken: mail).count, 2)
        XCTAssertLessThan(WakeService.novelTail(heard: "pre sehr", spoken: said).count, 2)
        XCTAssertLessThan(WakeService.novelTail(heard: "del master mind", spoken: mail).count, 2)
        // Pause first, then decide: three words or a stop word is the user, less is a false alarm and Jarvis resumes.
        XCTAssertTrue(WakeService.isRealInterruption("aspetta"))
        XCTAssertTrue(WakeService.isRealInterruption("parliamo di Giulia"))
        XCTAssertFalse(WakeService.isRealInterruption("mind cioè"))
        XCTAssertFalse(WakeService.isRealInterruption("cad pro"))
    }
}
