import XCTest

@testable import OrbitCore

final class LiveCLITests: XCTestCase {
  func testRealCodexRouterStartAndResume() async throws {
    guard ProcessInfo.processInfo.environment["ORBIT_LIVE_TESTS"] == "1" else {
      throw XCTSkip("Opt-in test uses the local Codex login: ORBIT_LIVE_TESTS=1")
    }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      "orbit-live-check-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    var snapshot = Snapshot()
    let project = Workspace(name: "OrbitDemo", directory: folder.path, access: .readOnly)
    snapshot.workspaces = [project]
    let decision = try await Routing.interpret(
      "Nel progetto OrbitDemo rispondi con la parola pronto, senza leggere o modificare file.",
      snapshot: snapshot)
    XCTAssertEqual(decision.action, .start)
    XCTAssertEqual(decision.projectID?.lowercased(), project.id.uuidString.lowercased())
    var job = Job(workspace: project, request: decision.task, model: ModelChoice())
    var invocation = try AgentCLI.worker(
      job, settings: snapshot.settings,
      prompt: "Rispondi solo pronto. Non usare strumenti e non leggere o modificare file.",
      resuming: false)
    // Keep this test independent of optional MCP services in the user's normal CLI config.
    invocation.arguments.insert("--ignore-user-config", at: 1)
    let first = try await ProcessStream().collect(invocation)
    let events = first.split(separator: "\n").flatMap {
      EventDecoder.decode(String($0), agent: .codex)
    }
    job.resumeID = events.compactMap { if case .session(let id) = $0 { id } else { nil } }.first
    XCTAssertNotNil(job.resumeID)
    XCTAssertTrue(
      events.contains {
        if case .answer(let text) = $0 { text.lowercased().contains("pronto") } else { false }
      })
    var resume = try AgentCLI.worker(
      job, settings: snapshot.settings,
      prompt:
        "Ricordi la parola che ti ho appena chiesto? Rispondi solo con quella parola, senza strumenti.",
      resuming: true)
    resume.arguments.insert("--ignore-user-config", at: 1)
    let second = try await ProcessStream().collect(resume)
    let resumed = second.split(separator: "\n").flatMap {
      EventDecoder.decode(String($0), agent: .codex)
    }
    XCTAssertTrue(
      resumed.contains {
        if case .answer(let text) = $0 { text.lowercased().contains("pronto") } else { false }
      })
  }
}

@MainActor final class LiveAppServerTests: XCTestCase {
  func testRealInteractiveThreadKeepsContextOnResume() async throws {
    guard ProcessInfo.processInfo.environment["ORBIT_LIVE_TESTS"] == "1" else {
      throw XCTSkip("Opt-in real app-server test uses the existing Codex CLI login")
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "orbit-appserver-live-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var job = Job(
      workspace: Workspace(name: "Fixture", directory: root.path, access: .readOnly), request: "",
      model: ModelChoice())
    var answers: [String] = []
    for prompt in [
      "Remember this marker: orbit-7319. Reply only with that marker. Do not read files or use tools.",
      "What marker did I ask you to remember? Reply only with the marker, without tools.",
    ] {
      let session = CodexSession()
      let invocation = try CodexServer.invocation(job, settings: Settings(), folder: root)
      for await event in session.events(invocation: invocation, job: job, prompt: prompt) {
        switch event {
        case .session(let id):
          if let previous = job.resumeID { XCTAssertEqual(id, previous) }
          job.resumeID = id
        case .answer(let value): answers.append(value)
        case .request(let ask): try await session.respond(ask.id, accept: false)
        case .finished(let error): XCTAssertNil(error)
        default: break
        }
      }
    }
    XCTAssertNotNil(job.resumeID)
    XCTAssertEqual(answers.count, 2)
    XCTAssertTrue(answers.allSatisfy { $0.contains("orbit-7319") })
  }
}
