import XCTest

@testable import OrbitCore

final class CodexProtocolTests: XCTestCase {
  func testFullAccessOnlyApprovesExecutionAndKnownComputerUseAccess() throws {
    let command = AgentPrompt(
      id: 1, method: "item/commandExecution/requestApproval",
      params: ["availableDecisions": ["accept", "decline"]])
    XCTAssertNil(try command.automaticResponse(access: .project))
    XCTAssertEqual(try command.automaticResponse(access: .full), ["decision": "accept"])
    let permission = AgentPrompt(
      id: 2, method: "item/permissions/requestApproval",
      params: ["permissions": ["network": ["enabled": true]]])
    XCTAssertEqual(
      try permission.automaticResponse(access: .full),
      ["permissions": ["network": ["enabled": true]], "scope": "turn"])
    var params: JSONValue = [
      "mode": "form", "serverName": "cua_repl",
      "message": "Allow Computer Use to use \"WhatsApp\"?",
      "requestedSchema": ["type": "object", "properties": [:]],
    ]
    func prompt(_ p: JSONValue) -> AgentPrompt {
      AgentPrompt(id: "cua", method: "mcpServer/elicitation/request", params: p)
    }
    XCTAssertNil(try prompt(params).automaticResponse(access: .readOnly))
    XCTAssertEqual(
      try prompt(params).automaticResponse(access: .full),
      ["action": "accept", "content": [:]])
    var fields = params.object
    fields["serverName"] = "other_server"
    XCTAssertNil(try prompt(.object(fields)).automaticResponse(access: .full))
    fields = params.object
    fields["message"] = "Send this message?"
    XCTAssertNil(try prompt(.object(fields)).automaticResponse(access: .full))
    fields = params.object
    fields["requestedSchema"] = ["type": "object", "properties": ["answer": ["type": "string"]]]
    XCTAssertNil(try prompt(.object(fields)).automaticResponse(access: .full))
    fields = params.object
    fields["requestedSchema"] = ["type": "object", "properties": [:], "required": ["missing"]]
    XCTAssertNil(try prompt(.object(fields)).automaticResponse(access: .full))
    params = ["mode": "url", "url": "https://example.com/login"]
    XCTAssertNil(try prompt(params).automaticResponse(access: .full))
    let question = AgentPrompt(
      id: 3, method: "item/tool/requestUserInput",
      params: ["questions": [["id": "q", "question": "Which project?"]]])
    XCTAssertNil(try question.automaticResponse(access: .full))
  }
  func testFullAccessPreferenceIsOptInAndPersists() throws {
    var settings = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
    XCTAssertFalse(settings.fullAccess)
    settings.fullAccess = true
    XCTAssertTrue(
      try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings)).fullAccess)
  }
  func testApprovalDoesNotGrantPersistentRulesOrBroaderPermissions() throws {
    let command = AgentPrompt(
      id: "server-id", method: "item/commandExecution/requestApproval",
      params: [
        "command": "echo test", "availableDecisions": ["accept", "acceptForSession", "decline"],
      ])
    XCTAssertEqual(try command.response(accept: true), ["decision": "accept"])
    let permissions: JSONValue = [
      "network": ["enabled": true], "fileSystem": ["write": ["/tmp/example"]],
    ]
    let ask = AgentPrompt(
      id: 5, method: "item/permissions/requestApproval", params: ["permissions": permissions])
    XCTAssertEqual(try ask.response(accept: true), ["permissions": permissions, "scope": "turn"])
    XCTAssertEqual(try ask.response(accept: false), ["permissions": [:], "scope": "turn"])
    let unsupported = AgentPrompt(
      id: 1, method: "item/commandExecution/requestApproval",
      params: ["availableDecisions": ["acceptForSession", "cancel"]])
    XCTAssertFalse(unsupported.canAccept)
    XCTAssertEqual(try unsupported.response(accept: false), ["decision": "cancel"])
  }
  func testQuestionAndFormValidationKeepTypesAndRequiredAnswers() throws {
    let ask = AgentPrompt(
      id: 1, method: "item/tool/requestUserInput",
      params: ["questions": [["id": "pick", "question": "Choose"]]])
    XCTAssertThrowsError(try ask.response(accept: true))
    let duplicate = AgentPrompt(
      id: 1, method: "item/tool/requestUserInput",
      params: ["questions": [["id": "same"], ["id": "same"]]])
    XCTAssertFalse(duplicate.canAccept)
    XCTAssertNoThrow(try duplicate.response(accept: false))
    XCTAssertEqual(
      try ask.response(accept: true, answers: ["pick": "Green"]),
      ["answers": ["pick": ["answers": ["Green"]]]])
    let schema: JSONValue = [
      "type": "object", "required": ["count", "ok", "color"],
      "properties": [
        "count": ["type": "integer", "minimum": 1, "maximum": 3], "ok": ["type": "boolean"],
        "color": ["type": "string", "oneOf": [["const": "green", "title": "Green"]]],
      ],
    ]
    let form = AgentPrompt(
      id: "mcp", method: "mcpServer/elicitation/request",
      params: ["mode": "form", "requestedSchema": schema])
    let content: JSONValue = ["count": 2, "ok": false, "color": "green"]
    XCTAssertEqual(
      try form.response(accept: true, form: content), ["action": "accept", "content": content])
    XCTAssertThrowsError(
      try form.response(accept: true, form: ["count": 4, "ok": true, "color": "green"]))
    XCTAssertThrowsError(
      try form.response(accept: true, form: ["count": 2, "ok": "false", "color": "green"]))
    XCTAssertThrowsError(
      try form.response(accept: true, form: ["count": 2, "ok": false, "color": "red"]))
    let nested = AgentPrompt(
      id: 4, method: "mcpServer/elicitation/request",
      params: [
        "mode": "form",
        "requestedSchema": ["type": "object", "properties": ["nested": ["type": "object"]]],
      ])
    XCTAssertFalse(nested.canAccept)
    XCTAssertThrowsError(try nested.response(accept: true))
  }
  func testLocalIsolationAndBrowserTokenScopeInAppServer() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "orbit-local-test-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    var settings = Settings()
    settings.codexExecutable = "/bin/echo"
    var job = Job(
      workspace: Workspace(name: "Local", directory: FileManager.default.temporaryDirectory.path),
      request: "", model: ModelChoice(provider: .ollama, model: "local-test"))
    let connection = BrowserConnection(
      url: "http://127.0.0.1:12345/mcp", token: "private-test-token")
    let isolated = try CodexServer.invocation(
      job, settings: settings, folder: root, browser: connection)
    XCTAssertTrue(isolated.arguments.contains("app-server"))
    XCTAssertEqual(
      isolated.environment?["CODEX_HOME"],
      root.appendingPathComponent("codex-local/\(job.id.uuidString)").path)
    XCTAssertTrue(
      isolated.arguments.contains("mcp_servers.orbit_browser.url=\"http://127.0.0.1:12345/mcp\""))
    XCTAssertFalse(isolated.arguments.joined().contains(connection.token))
    XCTAssertEqual(isolated.environment?["ORBIT_BROWSER_TOKEN"], connection.token)
    job.model.integrations = true
    let shared = try CodexServer.invocation(job, settings: settings, folder: root)
    XCTAssertEqual(
      shared.environment?["CODEX_HOME"], ProcessInfo.processInfo.environment["CODEX_HOME"])
    XCTAssertFalse(shared.arguments.contains("features.plugins=false"))
    XCTAssertFalse(shared.arguments.contains("--ignore-user-config"))
  }
  func testMCPURLRejectsCredentialsAndNonWebSchemes() {
    for value in ["file:///etc/passwd", "javascript:alert(1)", "https://user:password@example.com"]
    {
      let prompt = AgentPrompt(
        id: 1, method: "mcpServer/elicitation/request",
        params: ["mode": "url", "url": .string(value)])
      XCTAssertNil(prompt.url)
      XCTAssertFalse(prompt.canAccept)
    }
  }
}
