import XCTest
import AppKit
import SwiftUI
@testable import Jarvis

final class NativeAgentIntegrationTests: XCTestCase {
    @MainActor func testNativeControlsPanelPreviews() throws {
        guard let path = ProcessInfo.processInfo.environment["ORBIT_NATIVE_PREVIEW_DIR"] else { throw XCTSkip("Set ORBIT_NATIVE_PREVIEW_DIR to export native controls UI") }
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let output = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        func export<V: View>(_ content: V, name: String, width: CGFloat, height: CGFloat) throws {
            let view = NSHostingView(rootView: content.preferredColorScheme(.dark))
            view.frame = NSRect(x: 0, y: 0, width: width, height: height)
            let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view; window.appearance = NSAppearance(named: .darkAqua); view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
            window.contentView = nil
        }
        let owner = Coordinator(enableServices: false, sessionRoot: root)
        owner.settings.settings = Settings()
        try export(AgentsTab(coordinator: owner).frame(width: 640, height: 1500), name: "native-settings", width: 640, height: 1500)
        for scope in ["allow_once", "allow_turn"] {
            let configuration = AgentExecutionConfiguration(agent: .codex, permissionMode: .acceptEdits, interactiveControls: true)
            let turn = SessionTurn(task: "Esporta il report della verifica", configuration: configuration, state: .dispatched)
            let approval = AgentApproval(requestID: .number(900), remoteSessionID: "preview", toolCallID: "command",
                title: scope == "allow_turn" ? "Accesso aggiuntivo per il turno" : "Esecuzione di un comando",
                details: "Esportazione del report richiesto\n\nComando:\nprintf 'report' > /tmp/orbit-report.txt\n\nDirectory: /progetti/OrbitHarnessTest",
                options: [ApprovalOption(optionID: "deny", name: "Reject", kind: "reject_once"), ApprovalOption(optionID: "allow", name: "Allow", kind: scope)])
            let session = Session(id: "s_01", projectName: "Website", projectPath: "/progetti/Website", agent: .codex,
                task: turn.task, status: .needsInput, executionConfiguration: configuration, turns: [turn], currentTurnID: turn.id, approvals: [approval])
            let card = SessionCard(session: session, now: Date(), onOpen: {}, onLog: {}, onReply: { _ in }, onStop: {}, onDismiss: {})
            try export(card.padding(12).frame(width: 380), name: "native-" + scope, width: 380, height: 600)
        }
    }
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OrbitNative-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    @MainActor private func owner(_ root: URL, scenario: [String: Any] = [:]) throws -> Coordinator {
        let peer = try XCTUnwrap(Bundle.module.url(forResource: "native-agent-peer", withExtension: "py", subdirectory: "Fixtures"))
        for name in ["codex", "claude"] {
            let executable = root.appendingPathComponent(name)
            try Data(contentsOf: peer).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }
        try JSONSerialization.data(withJSONObject: scenario).write(to: root.appendingPathComponent("native-scenario.json"))
        let owner = Coordinator(enableServices: false, sessionRoot: root)
        owner.settings.settings = Settings()
        owner.settings.settings.speakSummaries = false; owner.settings.settings.openResults = false
        owner.settings.settings.codexPathOverride = root.appendingPathComponent("codex").path
        owner.settings.settings.claudePathOverride = root.appendingPathComponent("claude").path
        owner.settings.settings.codexModel = "frozen-codex"
        owner.settings.settings.codingModel = "frozen-claude"
        return owner
    }
    @MainActor private func wait(seconds: Double = 5, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(seconds)
        while !condition() && Date() < end { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "Native transport did not reach the expected state")
    }
    private func records(_ root: URL, _ name: String = "native-wire.jsonl") throws -> [[String: Any]] {
        try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8).split(whereSeparator: \.isNewline).map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }
    @MainActor private func start(_ owner: Coordinator, root: URL, agent: AgentKind) throws -> Session {
        XCTAssertTrue(owner.spawn(project: Project(name: "Test", path: root.path, defaultAgent: agent), agent: agent, task: "Task", coding: true))
        return try XCTUnwrap(owner.sessions.sessions.first)
    }

    @MainActor func testBothNativeProtocolsRequireExplicitOneShotDecisionAndKeepAuthenticationInCLI() async throws {
        for agent in [AgentKind.codex, .claude] {
            for choice in ["allow", "deny"] {
                let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
                let owner = try owner(root); defer { owner.stopAll() }
                let session = try start(owner, root: root, agent: agent)
                try await wait { owner.sessions.session(session.id)?.pendingApprovals.count == 1 }
                let approval = try XCTUnwrap(owner.sessions.session(session.id)?.pendingApprovals.first)
                XCTAssertTrue(owner.sessions.session(session.id)?.offersSteering == true)
                XCTAssertEqual(approval.turnID, owner.sessions.session(session.id)?.currentTurnID)
                XCTAssertEqual(Set(approval.options.map(\.kind)), ["allow_once", "reject_once"])
                XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("approved.txt").path))
                XCTAssertTrue(owner.resolveApproval(sessionID: session.id, approvalID: approval.id, optionID: choice))
                XCTAssertFalse(owner.resolveApproval(sessionID: session.id, approvalID: approval.id, optionID: choice))
                try await wait { owner.sessions.session(session.id)?.currentTurnID == nil }
                XCTAssertEqual(owner.sessions.session(session.id)?.status, .done)
                XCTAssertEqual(FileManager.default.fileExists(atPath: root.appendingPathComponent("approved.txt").path), choice == "allow")
                let launches = try records(root, "native-launches.jsonl")
                let args = try XCTUnwrap(launches[0]["args"] as? [String])
                XCTAssertFalse(args.contains("--bare")); XCTAssertFalse(args.contains("--dangerously-skip-permissions"))
                XCTAssertFalse(args.contains("--dangerously-bypass-approvals-and-sandbox"))
                let journal = try SessionJournal(url: root.appendingPathComponent("session-events.jsonl")).replay()
                XCTAssertEqual(journal.filter { $0.kind == .approvalDecided }.count, 1)
                if agent == .codex {
                    let responses = try records(root).filter { $0["id"] as? Int == 900 && $0["result"] != nil }
                    XCTAssertEqual(responses.count, 1)
                    XCTAssertEqual((responses[0]["result"] as? [String: String])?["decision"], choice == "allow" ? "accept" : "decline")
                } else {
                    let response = try XCTUnwrap(try records(root).first { $0["type"] as? String == "control_response" })
                    let payload = (response["response"] as? [String: Any])?["response"] as? [String: Any]
                    XCTAssertEqual(payload?["behavior"] as? String, choice == "allow" ? "allow" : "deny")
                    XCTAssertNil(payload?["updatedPermissions"])
                }
            }
        }
    }

    @MainActor func testSteeringExpiresPendingApprovalAndResumesSameContextBeforeQueuedFollowup() async throws {
        for agent in [AgentKind.codex, .claude] {
            let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
            let owner = try owner(root, scenario: ["mode": "steer"]); defer { owner.stopAll() }
            let session = try start(owner, root: root, agent: agent)
            try await wait { owner.sessions.session(session.id)?.pendingApprovals.count == 1 }
            let approval = try XCTUnwrap(owner.sessions.session(session.id)?.pendingApprovals.first)
            let remoteID = try XCTUnwrap(owner.sessions.session(session.id)?.agentSessionID)
            XCTAssertTrue(owner.followUp(session: try XCTUnwrap(owner.sessions.session(session.id)), task: "Queued followup"))
            owner.settings.settings.codexModel = "changed-model"; owner.settings.settings.codingModel = "changed-model"
            XCTAssertTrue(owner.steer(sessionID: session.id, task: "Use a dark theme"))
            XCTAssertFalse(owner.resolveApproval(sessionID: session.id, approvalID: approval.id, optionID: "allow"))
            XCTAssertFalse(owner.steer(sessionID: session.id, task: "Another steer"))
            try await wait { owner.sessions.session(session.id)?.currentTurnID == nil && owner.sessions.session(session.id)?.queuedTurns.isEmpty == true }
            let final = try XCTUnwrap(owner.sessions.session(session.id))
            XCTAssertEqual(final.status, .done)
            XCTAssertEqual(final.agentSessionID, remoteID)
            XCTAssertEqual(final.turns?.map(\.state), [.interrupted, .completed, .completed])
            XCTAssertEqual(final.approvals?.first?.state, .expired)
            XCTAssertEqual(final.turns?[1].configuration.model, agent == .codex ? "frozen-codex" : "frozen-claude")
            let frames = try records(root)
            XCTAssertFalse(frames.contains { ($0["result"] as? [String: String])?["decision"] == "accept" })
            XCTAssertEqual(try records(root, "native-launches.jsonl").count, 3)
            if agent == .codex {
                let resumes = frames.filter { $0["method"] as? String == "thread/resume" }
                XCTAssertEqual(resumes.count, 2)
                XCTAssertTrue(resumes.allSatisfy { ($0["params"] as? [String: String])?["threadId"] == remoteID })
            } else {
                let runs = try records(root, "native-launches.jsonl")
                let args = try XCTUnwrap(runs[1]["args"] as? [String])
                XCTAssertEqual(args[try XCTUnwrap(args.firstIndex(of: "--resume")) + 1], remoteID)
            }
        }
    }

    @MainActor func testUnacknowledgedInterruptionCannotAutomaticallyResumeEvenWithTerminalAndCleanExit() async throws {
        for agent in [AgentKind.codex, .claude] {
            let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
            let owner = try owner(root, scenario: ["mode": "steer", "terminalWithoutAck": true]); defer { owner.stopAll() }
            let session = try start(owner, root: root, agent: agent)
            try await wait { owner.sessions.session(session.id)?.pendingApprovals.count == 1 }
            XCTAssertTrue(owner.steer(sessionID: session.id, task: "New direction"))
            try await wait { owner.sessions.session(session.id)?.currentTurnID == nil }
            XCTAssertEqual(try records(root, "native-launches.jsonl").count, 1)
            XCTAssertEqual(owner.sessions.session(session.id)?.queuedTurns.count, 1)
            XCTAssertEqual(owner.sessions.session(session.id)?.status, .failed)
        }
    }

    @MainActor func testCancelNeverGrantsPermissionOrStartsQueuedTurn() async throws {
        for agent in [AgentKind.codex, .claude] {
            let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
            let owner = try owner(root); defer { owner.stopAll() }
            let session = try start(owner, root: root, agent: agent)
            try await wait { owner.sessions.session(session.id)?.pendingApprovals.count == 1 }
            let approval = try XCTUnwrap(owner.sessions.session(session.id)?.pendingApprovals.first)
            XCTAssertTrue(owner.followUp(session: try XCTUnwrap(owner.sessions.session(session.id)), task: "Queued"))
            owner.stop(sessionID: session.id)
            XCTAssertFalse(owner.resolveApproval(sessionID: session.id, approvalID: approval.id, optionID: "allow"))
            try await wait { owner.sessions.session(session.id)?.currentTurnID == nil }
            XCTAssertEqual(owner.sessions.session(session.id)?.status, .cancelled)
            XCTAssertEqual(owner.sessions.session(session.id)?.turns?.map(\.state), [.cancelled, .cancelled])
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("approved.txt").path))
        }
    }

    @MainActor func testDisconnectAndDuplicatePermissionIDsFailClosed() async throws {
        for agent in [AgentKind.codex, .claude] {
            for scenario: [String: Any] in [["exitWaiting": true], ["repeatID": true]] {
                let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
                let owner = try owner(root, scenario: scenario); defer { owner.stopAll() }
                let session = try start(owner, root: root, agent: agent)
                try await wait { owner.sessions.session(session.id)?.currentTurnID == nil }
                XCTAssertEqual(owner.sessions.session(session.id)?.status, .failed)
                XCTAssertTrue(owner.sessions.session(session.id)?.pendingApprovals.isEmpty == true)
                XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("approved.txt").path))
            }
        }
    }

    @MainActor func testPersistenceFailurePreventsGrantDelivery() async throws {
        for agent in [AgentKind.codex, .claude] {
            let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
            let owner = try owner(root); defer { owner.stopAll() }
            let session = try start(owner, root: root, agent: agent)
            try await wait { owner.sessions.session(session.id)?.pendingApprovals.count == 1 }
            let approval = try XCTUnwrap(owner.sessions.session(session.id)?.pendingApprovals.first)
            let journal = root.appendingPathComponent("session-events.jsonl")
            try FileManager.default.removeItem(at: journal); try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: false)
            XCTAssertFalse(owner.resolveApproval(sessionID: session.id, approvalID: approval.id, optionID: "allow"))
            try await wait { owner.sessions.session(session.id)?.currentTurnID == nil }
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("approved.txt").path))
        }
    }

    @MainActor func testCodexPermissionProfileGrantIsTurnScopedAndNeverPersistent() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let owner = try owner(root, scenario: ["permissionsScope": true]); defer { owner.stopAll() }
        let session = try start(owner, root: root, agent: .codex)
        try await wait { owner.sessions.session(session.id)?.pendingApprovals.count == 1 }
        let approval = try XCTUnwrap(owner.sessions.session(session.id)?.pendingApprovals.first)
        XCTAssertEqual(approval.options.first(where: { $0.optionID == "allow" })?.kind, "allow_turn")
        XCTAssertTrue(owner.resolveApproval(sessionID: session.id, approvalID: approval.id, optionID: "allow"))
        try await wait { owner.sessions.session(session.id)?.currentTurnID == nil }
        let reply = try XCTUnwrap(try records(root).first { $0["id"] as? Int == 900 && $0["result"] != nil })
        XCTAssertEqual((reply["result"] as? [String: Any])?["scope"] as? String, "turn")
    }

    @MainActor func testCodexCorrectionsKeepApprovalAndSteeringControls() async throws {
        for action in ["allow", "stop", "steer"] {
            let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
            let owner = try owner(root, scenario: ["mode": "complete", "correctionMode": action == "steer" ? "steer" : "approval"])
            defer { owner.stopAll() }
            XCTAssertTrue(owner.startWorkflow(project: Project(name: "Repair", path: root.path), agent: .codex,
                reviewer: .codex, task: "Implement", verificationCommand: "test -f corrected.txt", maxCorrections: 1))
            let id = try XCTUnwrap(owner.sessions.sessions.first?.id)
            try await wait { owner.sessions.session(id)?.pendingApprovals.count == 1 }
            let pending = try XCTUnwrap(owner.sessions.session(id)?.pendingApprovals.first)
            XCTAssertEqual(owner.sessions.session(id)?.workflow?.attempt, 1)
            XCTAssertTrue(owner.sessions.session(id)?.offersSteering == true)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("corrected.txt").path))
            if action == "allow" { XCTAssertTrue(owner.resolveApproval(sessionID: id, approvalID: pending.id, optionID: "allow")) }
            else if action == "stop" { owner.stop(sessionID: id) }
            else { XCTAssertTrue(owner.steer(sessionID: id, task: "Keep the correction and preserve the tests")) }
            try await wait { owner.sessions.session(id)?.currentTurnID == nil }
            let final = try XCTUnwrap(owner.sessions.session(id))
            XCTAssertEqual(final.workflow?.attempt, 1)
            if action == "stop" {
                XCTAssertEqual(final.workflow?.state, .cancelled)
                XCTAssertEqual(final.approvals?.first?.state, .cancelled)
                XCTAssertTrue(final.queuedTurns.isEmpty)
                XCTAssertEqual(try records(root, "native-launches.jsonl").count, 3)
                XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("corrected.txt").path))
            } else {
                XCTAssertEqual(final.workflow?.state, .completed)
                XCTAssertEqual(final.turns?.last?.exitCode, 0)
                let wire = try records(root)
                XCTAssertEqual(wire.filter { $0["method"] as? String == "thread/start" }.count, 2)
                XCTAssertEqual(wire.filter { $0["method"] as? String == "thread/resume" }.count, action == "steer" ? 1 : 0)
                if action == "steer" {
                    XCTAssertEqual(final.approvals?.first?.state, .expired)
                    XCTAssertEqual(final.turns?[4].workflowAttempt, 1)
                    XCTAssertEqual(final.turns?[4].repairSourceTurnID, final.turns?[2].id)
                    XCTAssertEqual(final.turns?[4].state, .completed)
                }
            }
        }
    }

    @MainActor func testNativeImplementationIntegratesWithReadOnlyReviewAndRealVerification() async throws {
        for agent in [AgentKind.codex, .claude] {
            let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
            let owner = try owner(root, scenario: ["mode": "complete"]); defer { owner.stopAll() }
            XCTAssertTrue(owner.startWorkflow(project: Project(name: "Test", path: root.path, defaultAgent: agent), agent: agent,
                reviewer: agent, task: "Implement", verificationCommand: "test -s implementation.txt"))
            let session = try XCTUnwrap(owner.sessions.sessions.first)
            try await wait { owner.sessions.session(session.id)?.workflow?.state == .completed }
            XCTAssertEqual(owner.sessions.session(session.id)?.turns?.map(\.state), [.completed, .completed, .completed])
            let runs = try records(root, "native-launches.jsonl")
            XCTAssertEqual(runs.map { $0["native"] as? Bool }, [true, false])
            let args = try XCTUnwrap(runs[1]["args"] as? [String])
            XCTAssertFalse(args.contains("--resume")); XCTAssertFalse(args.contains("resume"))
            XCTAssertTrue(args.contains(agent == .codex ? "read-only" : "Read,Glob,Grep"))
        }
    }

    func testNewDefaultsAndLegacySessionTransportAreIndependent() throws {
        let defaults = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
        XCTAssertTrue(defaults.codexInteractiveControls); XCTAssertTrue(defaults.claudeInteractiveControls)
        let old = try JSONDecoder().decode(AgentExecutionConfiguration.self, from: Data("{\"agent\":\"codex\",\"permissionMode\":\"acceptEdits\"}".utf8))
        XCTAssertFalse(old.supportsInteractiveControls)
        var readonly = old; readonly.interactiveControls = true; readonly.readOnly = true
        XCTAssertFalse(readonly.supportsInteractiveControls)
    }

    @MainActor func testIgnoredInterruptAndNonzeroExitNeverStartReplacementAutomatically() async throws {
        for scenario: [String: Any] in [["mode": "steer", "ignoreInterrupt": true], ["mode": "steer", "exitCode": 9]] {
            for agent in [AgentKind.codex, .claude] {
                let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
                let owner = try owner(root, scenario: scenario); defer { owner.stopAll() }
                let session = try start(owner, root: root, agent: agent)
                try await wait { owner.sessions.session(session.id)?.pendingApprovals.count == 1 }
                XCTAssertTrue(owner.steer(sessionID: session.id, task: "New direction"))
                try await wait(seconds: 13) { owner.sessions.session(session.id)?.currentTurnID == nil }
                XCTAssertEqual(try records(root, "native-launches.jsonl").count, 1)
                XCTAssertEqual(owner.sessions.session(session.id)?.queuedTurns.count, 1)
                XCTAssertEqual(owner.sessions.session(session.id)?.status, .failed)
            }
        }
    }

    @MainActor func testWorkflowSteeringChangesReviewRequirementAndPreservesStageOrder() async throws {
        for agent in [AgentKind.codex, .claude] {
            let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
            let owner = try owner(root, scenario: ["mode": "steer"]); defer { owner.stopAll() }
            XCTAssertTrue(owner.startWorkflow(project: Project(name: "Test", path: root.path, defaultAgent: agent), agent: agent,
                reviewer: agent, task: "Implement", verificationCommand: "test -s implementation.txt"))
            let session = try XCTUnwrap(owner.sessions.sessions.first)
            try await wait { owner.sessions.session(session.id)?.pendingApprovals.count == 1 }
            XCTAssertTrue(owner.steer(sessionID: session.id, task: "Use a dark theme"))
            try await wait { owner.sessions.session(session.id)?.workflow?.state == .completed }
            let final = try XCTUnwrap(owner.sessions.session(session.id))
            XCTAssertEqual(final.turns?.map(\.state), [.interrupted, .completed, .completed, .completed])
            XCTAssertTrue(final.workflow?.originalTask.contains("Use a dark theme") == true)
            XCTAssertTrue(final.turns?.first(where: { $0.workflowStage == .review })?.task.contains("Use a dark theme") == true)
            XCTAssertEqual(try records(root, "native-launches.jsonl").map { $0["native"] as? Bool }, [true, true, false])
        }
    }

    @MainActor func testNativeBackendFailureWithZeroExitCodeCannotAdvanceWorkflow() async throws {
        for agent in [AgentKind.codex, .claude] {
            let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
            let owner = try owner(root, scenario: ["mode": "complete", "status": "failed"]); defer { owner.stopAll() }
            XCTAssertTrue(owner.startWorkflow(project: Project(name: "Test", path: root.path, defaultAgent: agent), agent: agent,
                reviewer: agent, task: "Implement", verificationCommand: "touch must-not-run"))
            let session = try XCTUnwrap(owner.sessions.sessions.first)
            try await wait { owner.sessions.session(session.id)?.currentTurnID == nil }
            XCTAssertEqual(owner.sessions.session(session.id)?.workflow?.state, .failed)
            XCTAssertFalse(owner.sessions.session(session.id)?.canResumeQueue ?? true)
            XCTAssertEqual(try records(root, "native-launches.jsonl").count, 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("must-not-run").path))
        }
    }

    @MainActor func testGraphKeepsBothNativeToolApprovalsAndSteeringAfterPlanApproval() async throws {
        for agent in [AgentKind.codex, .claude] {
            for direction in [false, true] {
                let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
                let owner = try owner(root); defer { owner.stopAll() }
                var graph = WorkflowDefinition.standard
                graph.nodes[2].agent = agent; graph.nodes[3].agent = agent
                XCTAssertTrue(owner.startWorkflow(project: Project(name: "GraphNative", path: root.path, defaultAgent: agent), agent: agent, reviewer: agent,
                    task: "Implement the requirement", verificationCommand: "test -f " + (direction ? "implementation.txt" : "approved.txt"), definition: graph))
                let id = try XCTUnwrap(owner.sessions.sessions.first?.id)
                try await wait { owner.sessions.session(id)?.workflow?.awaitingPlanApproval == true }
                XCTAssertTrue(owner.decidePlan(sessionID: id, approve: true))
                try await wait { owner.sessions.session(id)?.pendingApprovals.count == 1 }
                let approval = try XCTUnwrap(owner.sessions.session(id)?.pendingApprovals.first)
                XCTAssertTrue(owner.sessions.session(id)?.offersSteering == true)
                if direction {
                    XCTAssertTrue(owner.steer(sessionID: id, task: "Use a dark theme"))
                } else {
                    XCTAssertTrue(owner.resolveApproval(sessionID: id, approvalID: approval.id, optionID: "allow"))
                }
                try await wait { owner.sessions.session(id)?.workflow?.state == .completed }
                let final = try XCTUnwrap(owner.sessions.session(id))
                XCTAssertEqual(final.workflow?.planApproved, true)
                XCTAssertEqual(final.turns?.last?.exitCode, 0)
                if direction {
                    XCTAssertTrue(final.turns?.first(where: { $0.workflowStage == .review })?.task.contains("Use a dark theme") == true)
                    XCTAssertTrue(final.turns?.contains(where: { $0.workflowNodeID == "implementation" && $0.state == .interrupted }) == true)
                }
            }
        }
    }

    func testNativeCodexArtifactDiscoveryHonorsCompletedItemsAndTurnBoundaries() {
        let changed = #"{"method":"item/completed","params":{"item":{"type":"fileChange","status":"completed","changes":[{"path":"index.html","kind":{"type":"add"}}]}}}"#
        XCTAssertEqual(SessionResult.viewable(ndjson: changed, resultText: "Done", projectPath: "/tmp/native")?.path, "/tmp/native/index.html")
        let opened = #"{"method":"item/completed","params":{"item":{"type":"commandExecution","command":"open index.html","exitCode":0}}}"#
        XCTAssertNil(SessionResult.viewable(ndjson: changed + "\n" + opened, resultText: "Done", projectPath: "/tmp/native"))
        XCTAssertNotNil(SessionResult.viewable(ndjson: opened + "\n{\"method\":\"turn/started\"}\n" + changed, resultText: "Done", projectPath: "/tmp/native"))
    }

    /// Opt-in: uses the user's existing CLI login in a disposable workspace.
    @MainActor func testRealInstalledCLIsCompleteUsingExistingLogin() async throws {
        guard ProcessInfo.processInfo.environment["ORBIT_NATIVE_LIVE"] == "1" else { throw XCTSkip("Set ORBIT_NATIVE_LIVE=1 for native provider smoke tests") }
        for agent in [AgentKind.codex, .claude] {
            if let selected = ProcessInfo.processInfo.environment["ORBIT_NATIVE_AGENT"], selected != agent.rawValue { continue }
            let executable = try XCTUnwrap(CLILocator.find(agent.cliName))
            let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
            let owner = Coordinator(enableServices: false, sessionRoot: root); defer { owner.stopAll() }
            owner.settings.settings = Settings()
            owner.settings.settings.speakSummaries = false; owner.settings.settings.openResults = false
            owner.settings.settings.codexModel = ""; owner.settings.settings.codingModel = ""
            if agent == .codex { owner.settings.settings.codexPathOverride = executable }
            else { owner.settings.settings.claudePathOverride = executable }
            XCTAssertTrue(owner.spawn(project: Project(name: "NativeSmoke", path: root.path, defaultAgent: agent), agent: agent,
                task: "Reply with exactly ORBIT_NATIVE_OK. Do not use any tools, inspect files, or open anything.", coding: true))
            let session = try XCTUnwrap(owner.sessions.sessions.first)
            try await wait(seconds: 90) { owner.sessions.session(session.id)?.currentTurnID == nil }
            let final = try XCTUnwrap(owner.sessions.session(session.id))
            XCTAssertEqual(final.status, .done, final.resultText)
            XCTAssertTrue(final.resultText.contains("ORBIT_NATIVE_OK"), final.resultText)
            XCTAssertNotNil(final.agentSessionID)
        }
    }

    @MainActor func testRealCodexApprovalAndSteeringUsingExistingLogin() async throws {
        guard ProcessInfo.processInfo.environment["ORBIT_NATIVE_LIVE_CODEX"] == "1" else { throw XCTSkip("Set ORBIT_NATIVE_LIVE_CODEX=1 for live approval and steering") }
        let executable = try XCTUnwrap(CLILocator.find("codex"))
        for steer in [false, true] {
            let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
            let workspace = root.appendingPathComponent("workspace")
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            let destination = root.appendingPathComponent("outside-workspace.txt")
            let owner = Coordinator(enableServices: false, sessionRoot: root); defer { owner.stopAll() }
            owner.settings.settings = Settings()
            owner.settings.settings.speakSummaries = false; owner.settings.settings.openResults = false
            owner.settings.settings.codexPathOverride = executable
            let task = "Use a shell command to write ORBIT_PERMISSION_OK into \(destination.path). This file is outside the workspace. Request the required sandbox approval before executing the command. Do not use apply_patch, other tools, or another destination. After execution reply ORBIT_PERMISSION_OK."
            XCTAssertTrue(owner.spawn(project: Project(name: "NativeLive", path: workspace.path), agent: .codex, task: task))
            let session = try XCTUnwrap(owner.sessions.sessions.first)
            try await wait(seconds: 90) { owner.sessions.session(session.id)?.pendingApprovals.isEmpty == false || owner.sessions.session(session.id)?.currentTurnID == nil }
            let pending = try XCTUnwrap(owner.sessions.session(session.id)?.pendingApprovals.first, owner.sessions.session(session.id)?.resultText ?? "No approval received")
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            if steer {
                let context = owner.sessions.session(session.id)?.agentSessionID
                XCTAssertTrue(owner.steer(sessionID: session.id, task: "Cancel the original file-writing task. Do not execute any commands or write files. Reply with exactly ORBIT_STEERING_OK."))
                try await wait(seconds: 90) { owner.sessions.session(session.id)?.currentTurnID == nil }
                let final = try XCTUnwrap(owner.sessions.session(session.id))
                XCTAssertEqual(final.status, .done, final.resultText)
                XCTAssertEqual(final.agentSessionID, context)
                XCTAssertEqual(final.turns?.map(\.state), [.interrupted, .completed])
                XCTAssertEqual(final.approvals?.first?.state, .expired)
                XCTAssertTrue(final.resultText.contains("ORBIT_STEERING_OK"), final.resultText)
                XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            } else {
                XCTAssertTrue(owner.resolveApproval(sessionID: session.id, approvalID: pending.id, optionID: "allow"))
                try await wait(seconds: 90) { owner.sessions.session(session.id)?.currentTurnID == nil }
                XCTAssertEqual(owner.sessions.session(session.id)?.status, .done, owner.sessions.session(session.id)?.resultText ?? "")
                XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "ORBIT_PERMISSION_OK")
            }
        }
    }
}
