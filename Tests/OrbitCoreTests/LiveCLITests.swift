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
