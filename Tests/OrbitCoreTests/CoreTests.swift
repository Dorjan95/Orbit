import XCTest

@testable import OrbitCore

final class CoreTests: XCTestCase {
  func temporary() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      "orbit-test-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
    return folder
  }
  func testWakeRecognizesNameWithOptionalGreetingAndExtractsCommand() {
    XCTAssertEqual(WakePhrase.command(in: "Orbit avvia il sito"), "avvia il sito")
    XCTAssertEqual(WakePhrase.command(in: "Orbit"), "")
    XCTAssertEqual(WakePhrase.command(in: "ORBIT!"), "")
    XCTAssertEqual(WakePhrase.command(in: "Hey Orbit, avvia il sito"), "avvia il sito")
    XCTAssertEqual(WakePhrase.command(in: "Ehi òrbit!"), "")
    XCTAssertNil(WakePhrase.command(in: "hey orbital"))
    XCTAssertNil(WakePhrase.command(in: "l’orbita della terra"))
    XCTAssertNil(WakePhrase.command(in: "un periodo orbitale"))
  }
  func testRecordingOnlyRemovesLeadingActivationPhrase() {
    XCTAssertEqual(
      WakePhrase.command(in: "  Hey Orbit, avvia il sito", atStartOnly: true), "avvia il sito")
    XCTAssertEqual(WakePhrase.command(in: "Orbit apri Docker", atStartOnly: true), "apri Docker")
    XCTAssertNil(WakePhrase.command(in: "Avvia Orbit in locale", atStartOnly: true))
  }
  func testVoiceLinkCannotChooseAnotherHost() {
    XCTAssertEqual(
      FishClient.voiceID(
        "https://fish.audio/app/text-to-speech/?modelId=104c93410aa94f7fa679dab02a0153cd"),
      "104c93410aa94f7fa679dab02a0153cd")
    XCTAssertNil(
      FishClient.voiceID("https://evil.example/?modelId=104c93410aa94f7fa679dab02a0153cd"))
    XCTAssertNil(FishClient.voiceID("../../secret"))
  }
  func testPartialSettingsKeepDefaults() throws {
    let settings = try JSONDecoder().decode(
      Settings.self, from: Data(#"{"maximumJobs":5,"mascotVisible":false}"#.utf8))
    XCTAssertEqual(settings.maximumJobs, 5)
    XCTAssertFalse(settings.mascotVisible)
    XCTAssertTrue(settings.handsFree)
  }
  func testStorageRoundtripAndPrivatePermissions() throws {
    let disk = DiskStore(folder: try temporary())
    var state = Snapshot()
    state.workspaces = [Workspace(name: "Example", directory: "/tmp")]
    state.memories = ["Italiano"]
    try disk.write(state)
    try disk.setCredential("fake-test-credential")
    XCTAssertEqual(try disk.read().workspaces.first?.name, "Example")
    XCTAssertEqual(disk.credential(), "fake-test-credential")
    let mode =
      try FileManager.default.attributesOfItem(atPath: disk.stateURL.path)[.posixPermissions]
      as? NSNumber
    XCTAssertEqual(mode?.intValue, 0o600)
    try disk.setCredential(nil)
    XCTAssertNil(disk.credential())
  }
  func testAmbiguousAliasReturnsEveryCandidate() {
    let p = [
      Workspace(name: "A", directory: "/tmp", aliases: ["il sito"]),
      Workspace(name: "B", directory: "/tmp", aliases: ["il sito"]),
    ]
    XCTAssertEqual(ProjectMatch.find("avvia il sito", in: p).count, 2)
    XCTAssertTrue(ProjectMatch.find("avvia la situazione", in: p).isEmpty)
  }
  func testRoutingRejectsUnknownAndCrossProjectSession() throws {
    var state = Snapshot()
    let a = Workspace(name: "A", directory: "/tmp")
    let b = Workspace(name: "B", directory: "/tmp")
    state.workspaces = [a, b]
    let job = Job(workspace: a, request: "test", model: ModelChoice())
    state.jobs = [job]
    XCTAssertThrowsError(
      try Routing.validate(
        Decision(action: .start, projectID: UUID().uuidString, task: "test"), snapshot: state))
    XCTAssertThrowsError(
      try Routing.validate(
        Decision(
          action: .resume, projectID: b.id.uuidString, sessionID: job.id.uuidString, task: "test"),
        snapshot: state))
    XCTAssertThrowsError(
      try Routing.validate(Decision(action: .resume, task: "test"), snapshot: state))
    XCTAssertNoThrow(
      try Routing.validate(
        Decision(
          action: .resume, projectID: a.id.uuidString, sessionID: job.id.uuidString, task: "test"),
        snapshot: state))
  }
  func testFiveProjectsHaveSeparateContext() throws {
    var state = Snapshot()
    for n in 1...5 {
      let p = Workspace(name: "Repo\(n)", directory: "/tmp/\(n)")
      state.workspaces.append(p)
      state.jobs.append(Job(workspace: p, request: "Task\(n)", model: ModelChoice()))
    }
    let context = Routing.context("continua", snapshot: state, selected: state.jobs[3].id)
    XCTAssertTrue(context.contains(state.jobs[3].id.uuidString))
    for p in state.workspaces { XCTAssertTrue(context.contains(p.name)) }
    XCTAssertTrue(context.contains("Non scegliere la sessione più recente"))
  }
  func testCodexAndClaudeStreaming() {
    XCTAssertEqual(
      EventDecoder.decode(#"{"type":"thread.started","thread_id":"abc"}"#, agent: .codex),
      [.session("abc")])
    XCTAssertEqual(
      EventDecoder.decode(
        #"{"type":"item.completed","item":{"type":"agent_message","text":"Done"}}"#, agent: .codex),
      [.answer("Done")])
    XCTAssertEqual(
      EventDecoder.decode(
        #"{"type":"result","permission_denials":[{}],"result":"Need approval"}"#, agent: .claude),
      [.inputNeeded("Need approval")])
    XCTAssertTrue(EventDecoder.decode("garbage", agent: .codex).isEmpty)
  }
  func testInvocationResumePinsSessionAndProvider() throws {
    let folder = try temporary()
    let executable = folder.appendingPathComponent("codex")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    var settings = Settings()
    settings.codexExecutable = executable.path
    var job = Job(
      workspace: Workspace(name: "A", directory: folder.path), request: "x",
      model: ModelChoice(provider: .ollama, model: "test:latest"))
    job.resumeID = "specific-id"
    let call = try AgentCLI.worker(
      job, settings: settings, prompt: "hello; $(ignored)", resuming: true)
    XCTAssertEqual(Array(call.arguments.suffix(3)), ["resume", "specific-id", "-"])
    XCTAssertTrue(call.arguments.contains("--oss"))
    XCTAssertEqual(call.input, "hello; $(ignored)")
    XCTAssertFalse(call.arguments.contains("--last"))
    XCTAssertFalse(call.arguments.contains("--dangerously-bypass-approvals-and-sandbox"))
  }
  func testInteractiveResumeRetainsProviderWithoutExecOnlyFlags() throws {
    var settings = Settings()
    settings.codexExecutable = "/bin/echo"
    var job = Job(
      workspace: Workspace(name: "A", directory: "/tmp", access: .readOnly), request: "x",
      model: ModelChoice(provider: .ollama, model: "fixture"))
    job.resumeID = "chosen-session"
    let call = try AgentCLI.interactive(job, settings: settings)
    XCTAssertTrue(call.arguments.contains("--oss"))
    XCTAssertTrue(call.arguments.contains("read-only"))
    XCTAssertFalse(call.arguments.contains("--ignore-user-config"))
    XCTAssertEqual(Array(call.arguments.suffix(2)), ["resume", "chosen-session"])
  }
  func testProcessDrainsBothPipesAndLastUnterminatedLine() async throws {
    let folder = try temporary()
    let executable = URL(fileURLWithPath: "/bin/sh")
    let run = ProcessStream()
    let output = try await run.collect(
      Invocation(
        executable: executable,
        arguments: [
          "-c",
          "i=0; while [ $i -lt 5000 ]; do echo diagnostic >&2; i=$((i+1)); done; cat; printf final",
        ], directory: folder, input: "hello\n"))
    XCTAssertEqual(output, "hello\nfinal")
  }
  func testProcessCancellationFinishes() async throws {
    let folder = try temporary()
    let run = ProcessStream()
    let task = Task {
      try await run.collect(
        Invocation(
          executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], directory: folder))
    }
    try await Task.sleep(for: .milliseconds(80))
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("Should cancel")
    } catch { XCTAssertTrue(error is CancellationError) }
  }
  func testImportDoesNotContinueRunningJobs() throws {
    let folder = try temporary()
    try Data(#"{"handsFree":false,"mascotSize":130}"#.utf8).write(
      to: folder.appendingPathComponent("settings.json"))
    try Data(#"[{"name":"Demo","path":"/tmp","permissionMode":"acceptEdits"}]"#.utf8).write(
      to: folder.appendingPathComponent("projects.json"))
    try Data(
      #"[{"projectName":"Demo","projectPath":"/tmp","task":"x","status":"running","agentSessionID":"resume-me"}]"#
        .utf8
    ).write(to: folder.appendingPathComponent("sessions.json"))
    let result = try ImportPreviousData.load(from: folder)
    XCTAssertFalse(result.settings.configured)
    XCTAssertFalse(result.settings.handsFree)
    XCTAssertEqual(result.jobs[0].status, .failed)
    XCTAssertEqual(result.jobs[0].resumeID, "resume-me")
    XCTAssertEqual(result.workspaces.count, 1)
  }
}
