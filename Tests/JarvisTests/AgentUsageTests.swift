import XCTest
import SwiftUI
import AppKit
@testable import Jarvis

final class AgentUsageTests: XCTestCase {
    func testCodexUsesAuthoritativeBucketsAndActualWindowDurations() throws {
        let data = Data(#"{"rateLimits":{"primary":{"usedPercent":90}},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":30,"windowDurationMins":10080,"resetsAt":1999999999},"secondary":null},"fast":{"limitName":"Rapido","primary":{"usedPercent":120,"windowDurationMins":300}}}}"#.utf8)
        let result = try XCTUnwrap(AgentUsageParser.codex(data))
        XCTAssertEqual(result.windows.map(\.label), ["7g", "Rapido · 5h"])
        XCTAssertEqual(result.windows.map(\.remainingPercent), [70, 0])
        XCTAssertEqual(result.windows[0].resetsAt?.timeIntervalSince1970, 1999999999)
        XCTAssertNil(result.windows[1].resetsAt)
    }
    func testClaudeReportsTruePercentagesAndOptionalModelWindows() throws {
        let result = try XCTUnwrap(AgentUsageParser.claude(Data(#"{"five_hour":{"utilization":0,"resets_at":"2030-01-01T10:00:00.000Z"},"seven_day":{"utilization":47.5,"resets_at":"2030-01-08T10:00:00Z"},"seven_day_opus":{"utilization":80},"seven_day_sonnet":null}"#.utf8)))
        XCTAssertEqual(result.windows.map(\.remainingPercent), [100, 52.5, 20])
        XCTAssertNotNil(result.windows[0].resetsAt); XCTAssertNotNil(result.windows[1].resetsAt)
    }
    func testMissingMalformedAndExpiredUsageNeverBecomeFullQuota() throws {
        XCTAssertNil(AgentUsageParser.codex(Data("{}".utf8)))
        XCTAssertNil(AgentUsageParser.claude(Data("{}".utf8)))
        let missing = try XCTUnwrap(AgentUsageParser.codex(Data(#"{"rateLimits":{"primary":{"usedPercent":null},"secondary":{"usedPercent":true}}}"#.utf8)))
        XCTAssertTrue(missing.windows.isEmpty); XCTAssertNotNil(missing.message)
        let negative = try XCTUnwrap(AgentUsageParser.claude(Data(#"{"five_hour":{"utilization":-2}}"#.utf8)))
        XCTAssertTrue(negative.windows.isEmpty)
        let now = Date()
        let snapshot = AgentUsageSnapshot(windows: [.init(label: "5h", usedPercent: 12, resetsAt: now.addingTimeInterval(20))], fetchedAt: now)
        XCTAssertTrue(snapshot.isCurrent(at: now)); XCTAssertFalse(snapshot.isCurrent(at: now.addingTimeInterval(21)))
        XCTAssertFalse(AgentUsageSnapshot(windows: [], fetchedAt: now.addingTimeInterval(-601)).isCurrent(at: now))
    }
    func testClaudeQuotaRequiresProfileScopeAndNeverRefreshesLogin() throws {
        func credential(scopes: [String], expiry: Double) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["claudeAiOauth": ["accessToken": "synthetic-test-token", "scopes": scopes, "expiresAt": expiry]])
        }
        let now = Date(timeIntervalSince1970: 1000)
        guard case .failure(.usagePermission) = AgentUsageService.claudeToken(from: try credential(scopes: ["user:inference"], expiry: 2000000), now: now) else { return XCTFail("Inference-only logins do not permit quota reads") }
        guard case .failure(.expired) = AgentUsageService.claudeToken(from: try credential(scopes: ["user:profile"], expiry: 900000), now: now) else { return XCTFail("Expired credentials must not be refreshed by Orbit") }
        guard case .success = AgentUsageService.claudeToken(from: try credential(scopes: ["user:profile"], expiry: 2000000), now: now) else { return XCTFail("Valid profile scope") }
    }
    @MainActor func testCodexQuotaRPCNeverCreatesThreadOrInvokesModel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("codex")
        let source = """
        #!/usr/bin/env python3
        import sys,json
        for line in sys.stdin:
            f=json.loads(line)
            if f['method']=='initialize':
                print(json.dumps({'id':1,'result':{}}),flush=True)
            elif f['method']=='account/rateLimits/read':
                print(json.dumps({'id':2,'result':{'rateLimits':{'primary':{'usedPercent':42,'windowDurationMins':300}}}}),flush=True)
            elif f['method']!='initialized':
                print(json.dumps({'id':f.get('id'),'error':{'message':'Inference forbidden'}}),flush=True)
                sys.exit(1)
        """
        try Data(source.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let result = await AgentUsageService.codex(executable: script.path)
        guard case .success(let snapshot) = result else { return XCTFail("Read-only RPC quota failed") }
        XCTAssertEqual(snapshot.windows.first?.remainingPercent, 58)
        let store = AgentUsageStore(enabled: false)
        await store.refresh(codexPath: script.path, claudePath: nil)
        XCTAssertNil(store.codex); XCTAssertFalse(store.refreshing)
    }
    @MainActor func testLiveReadOnlyAccountQuota() async throws {
        guard ProcessInfo.processInfo.environment["ORBIT_LIVE_QUOTA"] == "1" else { throw XCTSkip("Opt-in account quota query; no inference") }
        let codex = await AgentUsageService.codex(executable: CLILocator.find("codex"))
        let claude = await AgentUsageService.claude(executable: CLILocator.find("claude"))
        for (name, result) in [("Codex", codex), ("Claude", claude)] {
            switch result {
            case .success(let snapshot): print("\(name): " + snapshot.windows.map { "\($0.label) \($0.remainingPercent)% remaining" }.joined(separator: ", "))
            case .failure(let error): print("\(name): \(error.message)")
            }
        }
        guard case .success(let snapshot) = codex else { return XCTFail("Codex live quota unavailable") }
        XCTAssertFalse(snapshot.windows.isEmpty)
    }
    @MainActor func testOptionalMainWindowAndScoreUI() throws {
        guard let directory = ProcessInfo.processInfo.environment["ORBIT_USAGE_PREVIEW_DIR"] else { throw XCTSkip("Optional quota and score UI snapshots") }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let coordinator = Coordinator(enableServices: false, sessionRoot: root.appendingPathComponent("sessions"))
        coordinator.usage.codex = .init(windows: [.init(label: "5h", usedPercent: 42, resetsAt: .now.addingTimeInterval(7200)), .init(label: "7g", usedPercent: 18, resetsAt: .now.addingTimeInterval(200000))])
        coordinator.usage.claude = .init(windows: [.init(label: "5h", usedPercent: 12, resetsAt: .now.addingTimeInterval(10800)), .init(label: "7g", usedPercent: 36, resetsAt: .now.addingTimeInterval(300000))])
        func snapshot<V: View>(_ view: V, name: String, size: CGSize) throws {
            let hosting = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = hosting; hosting.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1)); hosting.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)); hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: root.appendingPathComponent(name + ".png"))
            window.contentView = nil
        }
        var scoreGraph = WorkflowDefinition.scoreLoop
        scoreGraph.nodes[0].agent = .claude
        for reduced in [false, true] {
            try snapshot(SettingsView(coordinator: coordinator, section: .sessions).transaction { $0.disablesAnimations = reduced }, name: reduced ? "main-reduced" : "main", size: CGSize(width: 820, height: 680))
            try snapshot(WorkflowEditorView(definition: .constant(scoreGraph), selectedNode: "score").transaction { $0.disablesAnimations = reduced }, name: reduced ? "score-reduced" : "score", size: CGSize(width: 1280, height: 820))
        }
        coordinator.usage.codex = .init(windows: [.init(label: "7g", usedPercent: 100, resetsAt: .now.addingTimeInterval(3600))])
        try snapshot(SettingsView(coordinator: coordinator, section: .agents), name: "exhausted", size: CGSize(width: 820, height: 680))
        coordinator.usage.claudeError = "Abilita l’accesso alle quote"
        coordinator.usage.claudeNeedsQuotaPermission = true
        coordinator.usage.codex = .init(windows: [], fetchedAt: .now.addingTimeInterval(-700))
        try snapshot(SettingsView(coordinator: coordinator, section: .workflows), name: "unavailable", size: CGSize(width: 820, height: 680))
    }
}
