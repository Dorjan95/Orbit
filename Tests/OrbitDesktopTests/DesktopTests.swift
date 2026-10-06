import AppKit
import OrbitCore
import RealityKit
import XCTest

@testable import OrbitDesktop

@MainActor final class DesktopTests: XCTestCase {
  func setupController(limit: Int = 5) throws -> (OrbitController, URL) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      "orbit-desktop-test-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
    let cli = folder.appendingPathComponent("fake-codex")
    let script = #"""
      #!/usr/bin/env python3
      import json,sys,time,os
      def send(value):
        print(json.dumps(value), flush=True)
      thread='thread-'+os.path.basename(os.getcwd())
      pending=None
      for line in sys.stdin:
        msg=json.loads(line)
        method=msg.get('method');params=msg.get('params',{});rid=msg.get('id')
        with open('argv.txt','a') as f: f.write(json.dumps(msg)+'\n')
        if method=='initialize':send({'id':rid,'result':{}})
        elif method in ['thread/start','thread/resume']:
          thread=params.get('threadId',thread)
          send({'id':rid,'result':{'thread':{'id':thread}}})
        elif method=='mcpServerStatus/list':send({'id':rid,'result':{'data':[{'name':'fixture','authStatus':'unsupported','tools':{'inspect':{}}}], 'nextCursor':None}})
        elif method=='turn/start':
          text=params['input'][0]['text']
          with open('requests.txt','a') as f:f.write(text+'\n')
          send({'id':rid,'result':{'turn':{'id':'turn'}}})
          time.sleep(.2)
          if 'approval' in text:
            pending='approval'
            send({'id':'approve-1','method':'item/commandExecution/requestApproval','params':{'threadId':thread,'turnId':'turn','itemId':'item','command':'echo reviewed','availableDecisions':['accept','decline']}})
          elif 'question' in text:
            pending='question'
            send({'id':42,'method':'item/tool/requestUserInput','params':{'threadId':thread,'turnId':'turn','itemId':'q','questions':[{'id':'color','header':'Colore','question':'Quale colore preferisci?'}]}})
          else:
            answer='ORBIT_INPUT_REQUIRED: Quale colore preferisci?' if 'need-input' in text else 'Completato e verificato.'
            send({'method':'item/completed','params':{'threadId':thread,'turnId':'turn','item':{'id':'answer','type':'agentMessage','text':answer}}})
            send({'method':'turn/completed','params':{'threadId':thread,'turn':{'id':'turn','status':'completed'}}})
        elif 'result' in msg and pending:
          answer=json.dumps(msg['result'])
          send({'method':'serverRequest/resolved','params':{'threadId':thread,'requestId':rid}})
          send({'method':'item/completed','params':{'threadId':thread,'turnId':'turn','item':{'id':'answer','type':'agentMessage','text':answer}}})
          send({'method':'turn/completed','params':{'threadId':thread,'turn':{'id':'turn','status':'completed'}}})
          pending=None
      """#
    try Data(script.utf8).write(to: cli)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
    let controller = OrbitController(
      disk: DiskStore(folder: folder.appendingPathComponent("data")), importLegacy: false)
    controller.settings.codexExecutable = cli.path
    controller.settings.maximumJobs = limit
    controller.settings.openResults = false
    controller.settings.announcements = false
    controller.settings.summaries = false
    for n in 1...5 {
      let directory = folder.appendingPathComponent("project-\(n)")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      controller.snapshot.workspaces.append(Workspace(name: "Repo\(n)", directory: directory.path))
    }
    addTeardownBlock { await MainActor.run { controller.shutdown() } }
    return (controller, folder)
  }
  func waitFor(_ condition: @escaping @MainActor () -> Bool) async throws {
    for _ in 0..<150 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(30))
    }
    XCTFail("Timed out")
  }
  func testFiveConcurrentRepositoriesAndPinnedResume() async throws {
    let (controller, _) = try setupController()
    for project in controller.snapshot.workspaces {
      controller.start(project, request: "task for \(project.name)")
    }
    XCTAssertEqual(controller.snapshot.jobs.filter { $0.status == .running }.count, 5)
    try await waitFor { controller.snapshot.jobs.allSatisfy { $0.status == .completed } }
    XCTAssertEqual(Set(controller.snapshot.jobs.compactMap(\.resumeID)).count, 5)
    let chosen = controller.snapshot.jobs[2]
    controller.continueJob(chosen.id, prompt: "continuazione solo Repo3")
    try await waitFor { controller.snapshot.jobs[2].status == .completed }
    for (n, project) in controller.snapshot.workspaces.enumerated() {
      let input = try String(
        contentsOf: project.url.appendingPathComponent("requests.txt"), encoding: .utf8)
      XCTAssertEqual(input.contains("continuazione solo Repo3"), n == 2)
      let args = try String(
        contentsOf: project.url.appendingPathComponent("argv.txt"), encoding: .utf8)
      if n == 2 {
        XCTAssertTrue(args.contains("thread/resume") && args.contains("thread-project-3"))
      } else {
        XCTAssertFalse(args.contains("thread/resume"))
      }
    }
  }
  func testCapacityQueueAndFollowupDoNotOverlap() async throws {
    let (controller, _) = try setupController(limit: 1)
    controller.start(controller.snapshot.workspaces[0], request: "first")
    let job = controller.snapshot.jobs[0]
    controller.continueJob(job.id, prompt: "followup")
    controller.start(controller.snapshot.workspaces[1], request: "second")
    XCTAssertEqual(controller.snapshot.jobs.filter { $0.status == .running }.count, 1)
    XCTAssertEqual(controller.snapshot.jobs[0].queued, ["followup"])
    try await waitFor {
      controller.snapshot.jobs.count == 2
        && controller.snapshot.jobs.allSatisfy { $0.status == .completed }
        && controller.snapshot.jobs[0].queued.isEmpty
    }
    let input = try String(
      contentsOf: controller.snapshot.workspaces[0].url.appendingPathComponent("requests.txt"),
      encoding: .utf8)
    XCTAssertTrue(input.contains("first"))
    XCTAssertTrue(input.contains("followup"))
  }
  func testNeedsInputRetainsContextAndCancelRemovesQueuedWork() async throws {
    let (controller, _) = try setupController(limit: 1)
    controller.start(controller.snapshot.workspaces[0], request: "need-input")
    try await waitFor { controller.snapshot.jobs[0].status == .waiting }
    XCTAssertEqual(controller.snapshot.jobs[0].result, "Quale colore preferisci?")
    XCTAssertNotNil(controller.snapshot.jobs[0].resumeID)
    controller.continueJob(controller.snapshot.jobs[0].id, prompt: "green")
    controller.start(controller.snapshot.workspaces[1], request: "queued")
    let cancelled = controller.snapshot.jobs[1].id
    controller.cancelJob(cancelled)
    try await waitFor { controller.snapshot.jobs[0].status == .completed }
    XCTAssertEqual(controller.snapshot.jobs[1].status, .cancelled)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: controller.snapshot.workspaces[1].url.appendingPathComponent("requests.txt").path))
  }
  func testApprovalsStayScopedToEachJobAndVoiceDoesNotApproveYes() async throws {
    let (controller, _) = try setupController()
    for n in 0..<2 { controller.start(controller.snapshot.workspaces[n], request: "approval") }
    try await waitFor { controller.prompts.count == 2 }
    let first = controller.snapshot.jobs[0].id
    let second = controller.snapshot.jobs[1].id
    // Different app-server processes are allowed to reuse request IDs.
    XCTAssertEqual(controller.prompts[first]?.first?.id, controller.prompts[second]?.first?.id)
    controller.continueJob(first, prompt: "sì")
    XCTAssertEqual(controller.prompts[first]?.count, 1)
    controller.continueJob(first, prompt: "approva")
    try await waitFor { controller.snapshot.jobs[0].status == .completed }
    XCTAssertTrue(controller.snapshot.jobs[0].result.contains("accept"))
    XCTAssertEqual(controller.snapshot.jobs[1].status, .waiting)
    controller.continueJob(second, prompt: "rifiuta")
    try await waitFor { controller.snapshot.jobs[1].status == .completed }
    XCTAssertTrue(controller.snapshot.jobs[1].result.contains("decline"))
  }
  func testLiveQuestionResponseAndCancelDoNotResumeAnotherTurn() async throws {
    let (controller, _) = try setupController()
    controller.start(controller.snapshot.workspaces[0], request: "question")
    try await waitFor { controller.prompts.count == 1 }
    let id = controller.snapshot.jobs[0].id
    controller.continueJob(id, prompt: "verde")
    try await waitFor { controller.snapshot.jobs[0].status == .completed }
    XCTAssertTrue(controller.snapshot.jobs[0].result.contains("verde"))
    XCTAssertEqual(controller.snapshot.jobs[0].queued, [])
    controller.start(controller.snapshot.workspaces[1], request: "approval")
    try await waitFor { controller.prompts.count == 1 }
    let cancelled = controller.snapshot.jobs[1].id
    controller.cancelJob(cancelled)
    XCTAssertNil(controller.prompts[cancelled])
    controller.respond(cancelled, request: "approve-1", accept: true)
    XCTAssertEqual(controller.snapshot.jobs[1].status, .cancelled)
  }
  func testCorruptDataIsPreserved() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "orbit-corrupt-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("state.json")
    let bytes = Data("{broken".utf8)
    try bytes.write(to: file)
    let controller = OrbitController(disk: DiskStore(folder: root), importLegacy: false)
    controller.settings.mascotVisible = false
    controller.persist()
    XCTAssertNotNil(controller.error)
    XCTAssertEqual(try Data(contentsOf: file), bytes)
  }
  func testModelSkeletonMatchesMotionAndAcceptsAnimatedPose() throws {
    if ProcessInfo.processInfo.environment["CI"] == "true" {
      throw XCTSkip("RealityKit asset loading needs a local graphics device")
    }
    let library = try XCTUnwrap(MotionLibrary.shared)
    let url = try XCTUnwrap(
      Bundle.module.url(forResource: "AeroMeshy", withExtension: "usdz", subdirectory: "Resources"))
    let entity = try Entity.load(contentsOf: url)
    func find(_ entity: Entity) -> ModelEntity? {
      if let model = entity as? ModelEntity, !model.jointNames.isEmpty { return model }
      for child in entity.children { if let value = find(child) { return value } }
      return nil
    }
    let model = try XCTUnwrap(find(entity))
    XCTAssertEqual(model.jointNames.count, 28)
    XCTAssertEqual(Set(model.jointNames), Set(library.jointNames))
    let animator = AeroView.Animator()
    animator.model = model
    animator.order = model.jointNames.map { library.jointNames.firstIndex(of: $0)! }
    animator.current = model.jointTransforms
    let before = model.jointTransforms
    animator.clipName = "Big_Wave_Hello"
    animator.input = AeroView(
      state: .greeting, epoch: Date(), settings: OrbitCore.Settings(),
      previewClip: "Big_Wave_Hello", scrub: 2)
    animator.tick()
    XCTAssertTrue(
      zip(before, model.jointTransforms).contains { $0.rotation.vector != $1.rotation.vector })
  }
  func testNativeMotionAssetCompleteAndFramesValid() throws {
    let library = try XCTUnwrap(MotionLibrary.shared)
    XCTAssertEqual(library.clips.count, 12)
    XCTAssertEqual(library.jointNames.count, 28)
    XCTAssertEqual(
      library.clip(for: .listening, settings: OrbitCore.Settings()), "Stand_to_Sit_Transition_M")
    for clip in library.clips.values {
      XCTAssertGreaterThan(clip.duration, 0)
      for frame in clip.frames {
        XCTAssertEqual(frame.count, library.jointNames.count)
        XCTAssertTrue(frame.allSatisfy { $0.count == 10 })
      }
    }
  }
}
