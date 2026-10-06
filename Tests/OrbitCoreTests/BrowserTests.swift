import XCTest

@testable import OrbitCore

final class BrowserTests: XCTestCase {
  func testBrowserIsAttachedOnlyToWorkerAndTokenIsNotInArguments() throws {
    var settings = Settings()
    settings.codexExecutable = "/bin/echo"
    settings.browserEnabled = true
    let folder = FileManager.default.temporaryDirectory
    let job = Job(
      workspace: Workspace(name: "Test", directory: folder.path, access: .readOnly),
      request: "open page", model: ModelChoice(provider: .ollama, model: "local-test"))
    let browser = BrowserConnection(url: "http://127.0.0.1:12345/mcp", token: "test-secret")
    let invocation = try AgentCLI.worker(
      job, settings: settings, prompt: "task", resuming: false, browser: browser)
    XCTAssertEqual(invocation.environment?["ORBIT_BROWSER_TOKEN"], "test-secret")
    XCTAssertFalse(invocation.arguments.joined().contains("test-secret"))
    XCTAssertTrue(invocation.arguments.contains("--ignore-user-config"))
    XCTAssertTrue(
      invocation.arguments.contains("mcp_servers.orbit_browser.url=\"http://127.0.0.1:12345/mcp\""))
    XCTAssertTrue(invocation.arguments.contains("read-only"))
    XCTAssertFalse(BrowserSupport.tools.contains("browser_evaluate"))
    XCTAssertTrue(
      invocation.arguments.contains(
        "mcp_servers.orbit_browser.default_tools_approval_mode=\"approve\""))
    XCTAssertFalse(BrowserSupport.tools.contains("browser_file_upload"))
    let interpreter = try AgentCLI.interpreter(
      settings: settings, directory: folder,
      schema: folder.appendingPathComponent("schema"), output: folder.appendingPathComponent("out"),
      prompt: "route")
    XCTAssertNil(interpreter.environment)
    XCTAssertFalse(interpreter.arguments.joined().contains("orbit_browser"))
    XCTAssertTrue(interpreter.arguments.contains("features.shell_tool=false"))
  }
  func testRoutingDescribesAppBrowserInsteadOfInterpreterTools() {
    let context = Routing.context(
      "Apri LinkedIn", snapshot: Snapshot(), selected: nil, browserAvailable: true)
    XCTAssertTrue(context.contains("\"browserAvailable\":true"))
    XCTAssertTrue(context.contains("projectID null"))
    XCTAssertTrue(context.contains("non rispondere che non hai strumenti"))
    let disabled = Routing.context("Apri LinkedIn", snapshot: Snapshot(), selected: nil)
    XCTAssertTrue(disabled.contains("\"browserAvailable\":false"))
  }
}
