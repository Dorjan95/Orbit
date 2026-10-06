import XCTest

@testable import OrbitCore

final class StubProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var respond: ((URLRequest) throws -> (Int, Data))?
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    do {
      let (status, bytes) = try Self.respond!(request)
      let response = HTTPURLResponse(
        url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"])!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: bytes)
      client?.urlProtocolDidFinishLoading(self)
    } catch { client?.urlProtocol(self, didFailWithError: error) }
  }
  override func stopLoading() {}
}
final class ServiceTests: XCTestCase {
  func session() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubProtocol.self]
    return URLSession(configuration: config)
  }
  override func tearDown() {
    StubProtocol.respond = nil
    super.tearDown()
  }
  func testDirectVoiceLinkUsesMetadataRatherThanSearch() async throws {
    StubProtocol.respond = { request in
      XCTAssertEqual(request.url?.host, "api.fish.audio")
      XCTAssertEqual(request.url?.path, "/model/104c93410aa94f7fa679dab02a0153cd")
      return (
        200,
        Data(
          #"{"_id":"104c93410aa94f7fa679dab02a0153cd","title":"Example voice","author":{"nickname":"Creator"}}"#
            .utf8)
      )
    }
    let result = try await FishClient(token: "fixture", session: session()).voices(
      "https://fish.audio/app/text-to-speech/?modelId=104c93410aa94f7fa679dab02a0153cd")
    XCTAssertEqual(result.items[0].title, "Example voice")
    XCTAssertFalse(result.more)
  }
  func testSearchEncodesTitleAndPagination() async throws {
    StubProtocol.respond = { request in
      let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
      XCTAssertEqual(query.first { $0.name == "title" }?.value, "a & b")
      XCTAssertEqual(query.first { $0.name == "page_number" }?.value, "2")
      return (200, Data(#"{"items":[],"has_more":true}"#.utf8))
    }
    let result = try await FishClient(token: "fixture", session: session()).voices("a & b", page: 2)
    XCTAssertTrue(result.more)
  }
  func testAutomaticCreditFallbackAndExplicitModelPreservation() async throws {
    var calls: [String] = []
    StubProtocol.respond = { request in
      let model = request.value(forHTTPHeaderField: "model") ?? ""
      calls.append(model)
      return model == "s2.1-pro"
        ? (402, Data(#"{"message":"Credit required"}"#.utf8)) : (200, Data("audio-fixture".utf8))
    }
    var settings = Settings()
    let client = FishClient(token: "fixture", session: session())
    let data = try await client.speech("hello", settings: settings)
    XCTAssertEqual(data, Data("audio-fixture".utf8))
    XCTAssertEqual(calls, ["s2.1-pro", "s2.1-pro-free"])
    calls = []
    settings.fishModel = "s2.1-pro"
    do {
      _ = try await client.speech("hello", settings: settings)
      XCTFail("Explicit paid model should report insufficient credit")
    } catch let error as ServiceError { XCTAssertEqual(error.status, 402) }
    XCTAssertEqual(calls, ["s2.1-pro"])
  }
  func testLocalModelsUseOnlyLoopbackAndParseProviders() async throws {
    StubProtocol.respond = { request in
      XCTAssertEqual(request.url?.host, "127.0.0.1")
      return request.url?.port == 11434
        ? (200, Data(#"{"models":[{"name":"local:latest"}]}"#.utf8))
        : (200, Data(#"{"data":[{"id":"local.gguf"}]}"#.utf8))
    }
    let ollama = try await LocalModels.list(.ollama, session: session())
    let studio = try await LocalModels.list(.lmstudio, session: session())
    XCTAssertEqual(ollama, ["local:latest"])
    XCTAssertEqual(studio, ["local.gguf"])
  }
}
