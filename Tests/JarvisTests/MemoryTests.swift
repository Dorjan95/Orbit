import XCTest
@testable import Jarvis

final class OrchestratorSanitizeTests: XCTestCase {
    private func open(task: String? = nil) -> OrchestratorAction {
        OrchestratorAction(action: .open, agent: nil, project: "Plumber Website", sessionID: nil, task: task, speak: "Opening.")
    }

    @MainActor func testLocalhostOpenBecomesWork() {
        let a = Coordinator.sanitize(open(), transcript: "open the plumber website on localhost")
        XCTAssertEqual(a.action, .followup)
        XCTAssertEqual(a.task, "open the plumber website on localhost")
    }

    @MainActor func testBrowserOpenWithTaskKeepsTask() {
        let a = Coordinator.sanitize(open(task: "run it on port 6000"), transcript: "run the hair salon site on localhost 6000 and open it in my browser")
        XCTAssertEqual(a.action, .followup)
        XCTAssertEqual(a.task, "run it on port 6000")
    }

    @MainActor func testLiteralTerminalStaysOpen() {
        XCTAssertEqual(Coordinator.sanitize(open(), transcript: "open a terminal in the plumber project").action, .open)
        XCTAssertEqual(Coordinator.sanitize(open(), transcript: "open the plumber folder").action, .open)
    }

    func testSchemaDecodesMemoryFields() throws {
        let json = #"{"action":"chitchat","agent":null,"project":null,"session_id":null,"task":null,"speak":"Got it.","remember":"Prefers Tailwind","forget":null}"#
        let a = try JSONDecoder().decode(OrchestratorAction.self, from: Data(json.utf8))
        XCTAssertEqual(a.remember, "Prefers Tailwind"); XCTAssertNil(a.forget)
    }

    func testAgentArgsCarryMemory() {
        let args = AgentRunner.arguments(agent: .claude, task: "x", mode: .bypassPermissions, resume: nil, extraGuidance: "Standing preferences:\n- Prefers Tailwind")
        let i = args.firstIndex(of: "--append-system-prompt")!
        XCTAssertTrue(args[i + 1].contains("Prefers Tailwind"))
        XCTAssertTrue(args[i + 1].contains("headlessly"))
    }
}

final class CueTests: XCTestCase {
    func testStripCues() {
        XCTAssertEqual(VoiceService.stripCues("[chuckles] Six already? [serious] Finish one first."), "Six already? Finish one first.")
        XCTAssertEqual(VoiceService.stripCues("On it."), "On it.")
    }
}

@MainActor final class ResolveTests: XCTestCase {
    func testPrefersMostSpecificProject() {
        let r = ProjectRegistry()
        r.projects = [Project(name: "website", path: "~/x"), Project(name: "New Construction Website", path: "~/y"), Project(name: "Plumber Website", path: "~/z", aliases: ["plumber"])]
        XCTAssertEqual(r.resolve("New Construction Website")?.name, "New Construction Website")
        XCTAssertEqual(r.resolve("the plumber site")?.name, "Plumber Website")
        XCTAssertEqual(r.resolve("website")?.name, "website")
        XCTAssertNil(r.resolve("bakery"))
    }
}

final class TranscriptNormalizeTests: XCTestCase {
    func testCodexVariants() {
        for v in ["use kodex for this", "tell codecs to fix it", "start co-dex on the plumber", "Code X should do it", "give it to Cortex"] {
            XCTAssertTrue(Coordinator.normalizeTranscript(v).contains("Codex"), v)
        }
        XCTAssertEqual(Coordinator.normalizeTranscript("tell claud to do it"), "tell Claude to do it")
        XCTAssertEqual(Coordinator.normalizeTranscript("deploy to the cloud"), "deploy to the cloud")
    }
}
