import XCTest
import SwiftUI
import AppKit
@testable import Jarvis

final class SessionRuntimeTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("OrbitRuntime-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func configuration(_ agent: AgentKind = .codex) -> AgentExecutionConfiguration {
        AgentExecutionConfiguration(agent: agent, permissionMode: .acceptEdits,
                                    model: agent == .claude ? "frozen-claude" : nil,
                                    codex: agent == .codex ? CodexBackend(model: "frozen-codex") : nil)
    }

    private func executable(in root: URL, agent: AgentKind = .codex, output: String, delay: Bool = true) throws -> URL {
        let url = root.appendingPathComponent(agent.rawValue)
        let script = """
        #!/bin/sh
        printf 'launch\n' >> launches.txt
        printf '%s\n' "$@" >> arguments.txt
        \(delay ? "/bin/sleep 0.1" : "")
        \(output)
        """
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    @MainActor
    private func coordinator(root: URL, executable: URL, agent: AgentKind = .codex) -> Coordinator {
        let value = Coordinator(enableServices: false, sessionRoot: root)
        value.settings.settings = Settings()
        value.settings.settings.codexInteractiveControls = false
        value.settings.settings.claudeInteractiveControls = false
        value.settings.settings.speakSummaries = false
        value.settings.settings.openResults = false
        if agent == .codex { value.settings.settings.codexPathOverride = executable.path }
        else { value.settings.settings.claudePathOverride = executable.path }
        return value
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "The runtime did not reach its expected state")
    }

    private var success: String {
        "printf '%s\\n' '{\"type\":\"thread.started\",\"thread_id\":\"remote-test\"}' '{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"Finished\"}}' '{\"type\":\"turn.completed\"}'"
    }

    @MainActor
    func testLegacySessionsMigrateWithoutChangingRemoteContext() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let original = Session(id: "s_09", projectName: "Legacy", projectPath: root.path, agent: .codex,
                               task: "Old work", status: .done, startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                               agentSessionID: "remote-old", resultText: "Old answer",
                               codexBackend: CodexBackend(model: "old-model"))
        JSONStore.save([original], to: root.appendingPathComponent("sessions.json"))
        let store = SessionStore(root: root)
        XCTAssertEqual(store.session(original.id), original)
        XCTAssertNil(store.persistenceError)
        XCTAssertEqual(store.nextID(), "s_10")
        let replay = try SessionJournal(url: root.appendingPathComponent("session-events.jsonl")).replay()
        XCTAssertEqual(replay.map(\.kind), [.migrated])
        XCTAssertEqual(SessionStore(root: root).session(original.id), original)
    }

    @MainActor
    func testCrashRecoveryRetainsOnlyUnsentRequestsAndUsesJournalOverStaleSnapshot() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        var active = SessionTurn(task: "Uncertain work", configuration: configuration(), state: .dispatched)
        active.dispatchedAt = Date()
        let queued = SessionTurn(task: "Unsent follow-up", configuration: configuration(), guidance: "Frozen memory")
        let original = Session(id: "s_13", projectName: "Recovery", projectPath: root.path, agent: .codex,
                               task: active.task, agentSessionID: "remote-existing", pid: 12345,
                               executionConfiguration: configuration(), turns: [active, queued], currentTurnID: active.id)
        let store = SessionStore(root: root)
        try store.save(original, kind: .dispatched, turnID: active.id)
        JSONStore.save([Session(id: original.id, projectName: "Stale", projectPath: root.path, agent: .codex,
                               task: "Stale snapshot", status: .done)], to: root.appendingPathComponent("sessions.json"))
        let recovered = try XCTUnwrap(SessionStore(root: root).session(original.id))
        XCTAssertEqual(recovered.status, .failed)
        XCTAssertEqual(recovered.turns?.first?.state, .interrupted)
        XCTAssertEqual(recovered.queuedTurns, [queued])
        XCTAssertEqual(recovered.agentSessionID, original.agentSessionID)
        XCTAssertEqual(recovered.executionConfiguration, original.executionConfiguration)
        XCTAssertNil(recovered.currentTurnID)
        XCTAssertNil(recovered.pid)
        XCTAssertEqual(SessionStore(root: root).session(original.id), recovered)
    }

    func testPartialTailIsDiscardedBeforeAnotherAppend() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("events.jsonl")
        let journal = SessionJournal(url: url)
        let session = Session(id: "s_01", projectName: "Test", projectPath: root.path, agent: .codex, task: "Work", status: .done)
        try journal.append(session, kind: .accepted)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("{\"version\":".utf8)); try handle.close()
        let restored = SessionJournal(url: url)
        XCTAssertEqual(try restored.replay().count, 1)
        try restored.append(session, kind: .finished)
        XCTAssertEqual(try SessionJournal(url: url).replay().map(\.sequence), [1, 2])
    }

    @MainActor
    func testSealedCorruptionAndFutureVersionBlockWritesWithoutOverwritingEvidence() throws {
        for future in [false, true] {
            let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
            let session = Session(id: "s_01", projectName: "Test", projectPath: root.path, agent: .codex, task: "Work", status: .done)
            let url = root.appendingPathComponent("session-events.jsonl")
            var data = Data("broken\n".utf8)
            if future {
                data = try JSONEncoder().encode(SessionJournalEvent(version: 2, sequence: 1, kind: .accepted, session: session))
                data.append(10)
            }
            try data.write(to: url)
            JSONStore.save([session], to: root.appendingPathComponent("sessions.json"))
            let store = SessionStore(root: root)
            let snapshotBefore = try Data(contentsOf: root.appendingPathComponent("sessions.json"))
            XCTAssertNotNil(store.persistenceError)
            XCTAssertThrowsError(try store.save(session, kind: .accepted))
            XCTAssertEqual(try Data(contentsOf: url), data)
            store.update(session.id) { $0.task = "Do not overwrite storage" }
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("sessions.json")), snapshotBefore)
        }
    }

    @MainActor
    func testInvalidLegacySnapshotIsNotSilentlyReplaced() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("sessions.json")
        let data = Data("broken".utf8)
        try data.write(to: url)
        let store = SessionStore(root: root)
        XCTAssertNotNil(store.persistenceError)
        XCTAssertEqual(try Data(contentsOf: url), data)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("session-events.jsonl").path))
    }

    @MainActor
    func testRestoredQueueWaitsForExplicitResumeAndKeepsItsRequestID() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let exe = try executable(in: root, output: success)
        let dispatched = SessionTurn(task: "Already sent", configuration: configuration(), state: .dispatched)
        let pending = SessionTurn(task: "Pending only", configuration: configuration())
        let original = Session(id: "s_01", projectName: "Recovered", projectPath: root.path, agent: .codex,
                               task: dispatched.task, agentSessionID: "remote-before-crash", codexBackend: configuration().codex,
                               executionConfiguration: configuration(), turns: [dispatched, pending], currentTurnID: dispatched.id)
        try SessionStore(root: root).save(original, kind: .dispatched, turnID: dispatched.id)
        let owner = coordinator(root: root, executable: exe)
        defer { owner.stopAll() }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("launches.txt").path))
        owner.resumePending(sessionID: original.id)
        XCTAssertEqual(owner.sessions.session(original.id)?.currentTurnID, pending.id)
        try await waitUntil { owner.sessions.session(original.id)?.currentTurnID == nil }
        let completed = try XCTUnwrap(owner.sessions.session(original.id))
        XCTAssertEqual(completed.turns?.map(\.state), [.interrupted, .completed])
        XCTAssertEqual(completed.task, pending.task)
        XCTAssertEqual(completed.resultText, "Finished")
        let args = try String(contentsOf: root.appendingPathComponent("arguments.txt"), encoding: .utf8)
        XCTAssertTrue(args.contains("resume\nremote-before-crash\n"))
        XCTAssertFalse(args.contains("Already sent"))
        XCTAssertEqual(SessionStore(root: root).session(original.id)?.turns?.map(\.id), [dispatched.id, pending.id])
    }

    @MainActor
    func testFollowupsRunFIFOWithoutParallelTurns() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let exe = try executable(in: root, output: success)
        let owner = coordinator(root: root, executable: exe)
        defer { owner.stopAll() }
        owner.settings.settings.codexModel = "frozen-codex"
        let project = Project(name: "FIFO", path: root.path)
        XCTAssertTrue(owner.spawn(project: project, agent: .codex, task: "First"))
        let initial = try XCTUnwrap(owner.sessions.sessions.first)
        let frozen = try XCTUnwrap(initial.executionConfiguration)
        owner.settings.settings.codexModel = "changed-model"
        owner.settings.settings.codexPermissionMode = .bypassPermissions
        owner.followUp(session: initial, task: "Second")
        owner.followUp(session: initial, task: "Third")
        let queued = try XCTUnwrap(owner.sessions.session(initial.id))
        XCTAssertEqual(queued.queuedTurns.map(\.task), ["Second", "Third"])
        XCTAssertTrue(queued.queuedTurns.allSatisfy { $0.configuration == frozen })
        try await waitUntil { owner.sessions.session(initial.id)?.turns?.allSatisfy { $0.state == .completed } == true }
        let final = try XCTUnwrap(owner.sessions.session(initial.id))
        XCTAssertEqual(final.turns?.map(\.task), ["First", "Second", "Third"])
        XCTAssertEqual(final.turns?.map(\.exitCode), [0, 0, 0])
        XCTAssertEqual(final.task, "Third")
        XCTAssertTrue(final.queuedTurns.isEmpty)
        let turns = try XCTUnwrap(final.turns)
        for index in 1..<turns.count {
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(turns[index].dispatchedAt), try XCTUnwrap(turns[index - 1].finishedAt))
        }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("launches.txt"), encoding: .utf8), "launch\nlaunch\nlaunch\n")
        let args = try String(contentsOf: root.appendingPathComponent("arguments.txt"), encoding: .utf8)
        XCTAssertFalse(args.contains("changed-model"))
        XCTAssertFalse(args.contains("--dangerously-bypass-approvals-and-sandbox"))
        XCTAssertEqual(args.components(separatedBy: "resume\nremote-test\n").count - 1, 2)
    }

    @MainActor
    func testBackendFailureWithZeroExitCodeDoesNotDrainQueue() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let exe = try executable(in: root, output: "printf '%s\\n' '{\"type\":\"turn.failed\",\"error\":{\"message\":\"Denied\"}}'")
        let owner = coordinator(root: root, executable: exe)
        defer { owner.stopAll() }
        XCTAssertTrue(owner.spawn(project: Project(name: "Failure", path: root.path), agent: .codex, task: "First"))
        let initial = try XCTUnwrap(owner.sessions.sessions.first)
        owner.followUp(session: initial, task: "Keep pending")
        try await waitUntil { owner.sessions.session(initial.id)?.currentTurnID == nil }
        let final = try XCTUnwrap(owner.sessions.session(initial.id))
        XCTAssertEqual(final.status, .failed)
        XCTAssertEqual(final.turns?.map(\.state), [.failed, .queued])
        XCTAssertEqual(final.turns?.first?.exitCode, 0)
        XCTAssertEqual(final.resultText, "Denied")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("launches.txt"), encoding: .utf8), "launch\n")
    }

    @MainActor
    func testClaudePermissionBlockPreservesQueueAndModelAcrossManualResume() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let exe = try executable(in: root, agent: .claude,
            output: "printf '%s\\n' '{\"type\":\"result\",\"session_id\":\"claude-remote\",\"permission_denials\":[{\"tool_name\":\"Bash\"}],\"is_error\":true,\"result\":\"Needs permission\"}'")
        let owner = coordinator(root: root, executable: exe, agent: .claude)
        defer { owner.stopAll() }
        owner.settings.settings.codingModel = "frozen-claude"
        let project = Project(name: "Claude", path: root.path, defaultAgent: .claude)
        XCTAssertTrue(owner.spawn(project: project, agent: .claude, task: "First", coding: true))
        let first = try XCTUnwrap(owner.sessions.sessions.first)
        owner.settings.settings.codingModel = "changed-claude"
        owner.followUp(session: first, task: "Second")
        try await waitUntil { owner.sessions.session(first.id)?.currentTurnID == nil }
        let blocked = try XCTUnwrap(owner.sessions.session(first.id))
        XCTAssertEqual(blocked.status, .needsInput)
        XCTAssertEqual(blocked.turns?.map(\.state), [.blocked, .queued])
        XCTAssertEqual(SessionStore(root: root).session(first.id)?.status, .needsInput)
        _ = try executable(in: root, agent: .claude,
            output: "printf '%s\\n' '{\"type\":\"result\",\"session_id\":\"claude-remote\",\"is_error\":false,\"result\":\"Done\"}'")
        owner.resumePending(sessionID: first.id)
        try await waitUntil { owner.sessions.session(first.id)?.status == .done }
        XCTAssertEqual(owner.sessions.session(first.id)?.turns?.map(\.state), [.blocked, .completed])
        let args = try String(contentsOf: root.appendingPathComponent("arguments.txt"), encoding: .utf8)
        XCTAssertTrue(args.contains("--resume\nclaude-remote\n"))
        XCTAssertEqual(args.components(separatedBy: "--model\nfrozen-claude\n").count - 1, 2)
        XCTAssertFalse(args.contains("changed-claude"))
    }

    @MainActor
    func testCancellationIsDurableAndCannotResurrectAStoppingSession() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let exe = try executable(in: root, output: success)
        let owner = coordinator(root: root, executable: exe)
        XCTAssertTrue(owner.spawn(project: Project(name: "Cancel", path: root.path), agent: .codex, task: "First"))
        let initial = try XCTUnwrap(owner.sessions.sessions.first)
        owner.followUp(session: initial, task: "Never start")
        owner.stop(sessionID: initial.id)
        owner.followUp(session: initial, task: "Do not resurrect")
        XCTAssertEqual(owner.sessions.session(initial.id)?.turns?.count, 2)
        XCTAssertTrue(owner.sessions.session(initial.id)?.queuedTurns.isEmpty == true)
        try await waitUntil { owner.sessions.session(initial.id)?.currentTurnID == nil }
        let restored = try XCTUnwrap(SessionStore(root: root).session(initial.id))
        XCTAssertEqual(restored.status, .cancelled)
        XCTAssertEqual(restored.turns?.map(\.state), [.cancelled, .cancelled])
        XCTAssertTrue(restored.queuedTurns.isEmpty)
        XCTAssertNil(restored.pid)
    }

    @MainActor
    func testPersistenceFailurePreventsLaunchingCLI() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let exe = try executable(in: root, output: success)
        let owner = coordinator(root: root, executable: exe)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("session-events.jsonl"), withIntermediateDirectories: false)
        XCTAssertFalse(owner.spawn(project: Project(name: "Storage error", path: root.path), agent: .codex, task: "Must not run"))
        XCTAssertNotNil(owner.sessions.persistenceError)
        XCTAssertTrue(owner.sessions.sessions.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("launches.txt").path))
    }

    @MainActor
    func testQueuedWorkSurvivesHistoryLimitAndClearFinished() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(root: root)
        let pending = Session(id: "s_01", projectName: "Pending", projectPath: root.path, agent: .codex,
                              task: "Old work", status: .failed, turns: [SessionTurn(task: "Still queued", configuration: configuration())])
        store.insert(pending)
        let stoppingID = UUID()
        store.insert(Session(id: "stopping", projectName: "Stopping", projectPath: root.path, agent: .codex,
                             task: "Waiting for process exit", status: .cancelled, currentTurnID: stoppingID))
        for index in 2...105 {
            store.insert(Session(id: "s_\(index)", projectName: "History", projectPath: root.path, agent: .codex, task: "Done", status: .done))
        }
        XCTAssertEqual(store.sessions.count, 100)
        XCTAssertNotNil(store.session(pending.id))
        XCTAssertNotNil(store.session("stopping"))
        store.clearFinished()
        XCTAssertFalse(try XCTUnwrap(store.session(pending.id)).dismissed)
        XCTAssertFalse(try XCTUnwrap(store.session("stopping")).dismissed)
        XCTAssertEqual(SessionStore(root: root).session(pending.id)?.queuedTurns.count, 1)
        XCTAssertEqual(SessionStore(root: root).sessions.count, 100)
    }

    @MainActor
    func testBackendRejectsUnsupportedLiveInputAndMismatchedAgent() throws {
        let backend: any AgentBackend = AgentRunner(sessionID: "contract", agent: .codex, onEvent: { _ in }, onExit: { _, _ in })
        XCTAssertTrue(backend.capabilities.resume)
        XCTAssertFalse(backend.capabilities.liveFollowup)
        XCTAssertFalse(backend.capabilities.interactiveApprovals)
        XCTAssertFalse(backend.capabilities.steering)
        XCTAssertThrowsError(try backend.sendFollowup("Live input"))
        XCTAssertThrowsError(try backend.start(AgentRunRequest(executable: "/bin/echo", task: "Work", cwd: "/tmp", resume: nil,
                                                              guidance: nil, configuration: configuration(.claude))))
        XCTAssertNil(backend.pid)
    }

    @MainActor
    func testRunnerDeliversEveryEventAndFinalPartialResultBeforeExit() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let output = """
        printf '%s\\n' '{"type":"thread.started","thread_id":"fast-thread"}'
        i=0
        while [ "$i" -lt 1000 ]; do
          printf '%s\\n' '{"type":"item.completed","item":{"type":"agent_message","text":"Progress"}}'
          i=$((i + 1))
        done
        printf '%s' '{"type":"turn.failed","error":{"message":"Final error without newline"}}'
        """
        let exe = try executable(in: root, output: output, delay: false)
        var received: [AgentEvent] = []
        var ended = false
        let runner = AgentRunner(sessionID: "fast-order", agent: .codex, onEvent: { received.append($0) }, onExit: { code, text in
            XCTAssertEqual(code, 0)
            XCTAssertEqual(received.count, 1002)
            XCTAssertEqual(received.first, .sessionID("fast-thread"))
            XCTAssertEqual(received.last, .result(text: "Final error without newline", isError: true))
            XCTAssertEqual(text, "Final error without newline")
            ended = true
        })
        try runner.start(AgentRunRequest(executable: exe.path, task: "Test", cwd: root.path, resume: nil,
                                        guidance: nil, configuration: configuration()))
        defer { runner.close() }
        try await waitUntil { ended }
    }

    @MainActor
    func testRecoveryPanelPreview() throws {
        guard let path = ProcessInfo.processInfo.environment["ORBIT_RUNTIME_PREVIEW_DIR"] else {
            throw XCTSkip("Set ORBIT_RUNTIME_PREVIEW_DIR to render the recovery panel")
        }
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(root: root)
        let interrupted = SessionTurn(task: "First", configuration: configuration(), state: .interrupted)
        let queued = SessionTurn(task: "Next", configuration: configuration())
        store.insert(Session(id: "preview", projectName: "Orbit", projectPath: root.path, agent: .codex,
                             task: "Controlla i test e poi rivedi il risultato.", status: .failed, finishedAt: Date(),
                             agentSessionID: "remote", turns: [interrupted, queued]))
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for compact in [false, true] {
            let content = SessionGroupsView(store: store, chord: .pushToTalk, onOpen: { _ in }, onLog: { _ in },
                                            onReply: { _, _ in }, onStop: { _ in }, onDismiss: { _ in })
                .padding(14).frame(width: compact ? 380 : 740).haloSurface(radius: 14)
            let view = NSHostingView(rootView: content)
            view.frame = NSRect(x: 0, y: 0, width: compact ? 380 : 740, height: 430)
            let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view; window.appearance = NSAppearance(named: .darkAqua)
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(compact ? "recovery.png" : "recovery-wide.png"))
            window.contentView = nil
        }
    }
}
