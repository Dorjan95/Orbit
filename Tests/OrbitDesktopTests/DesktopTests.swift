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
      #!/bin/sh
      printf '%s\n' "$@" >> argv.txt
      text=$(cat)
      printf '%s\n' "$text" >> requests.txt
      id=$(basename "$PWD")
      printf '{"type":"thread.started","thread_id":"thread-%s"}\n' "$id"
      sleep 0.2
      case "$text" in
        *"need-input"*) printf '{"type":"item.completed","item":{"type":"agent_message","text":"ORBIT_INPUT_REQUIRED: Quale colore preferisci?"}}\n' ;;
        *) printf '{"type":"item.completed","item":{"type":"agent_message","text":"Completato e verificato."}}\n' ;;
      esac
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
        XCTAssertTrue(args.contains("resume\nthread-project-3\n"))
      } else {
        XCTAssertFalse(args.contains("resume"))
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
