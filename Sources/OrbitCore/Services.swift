import Foundation

public struct Voice: Identifiable, Codable, Sendable, Hashable {
  public let id: String
  public let title: String
  public let author: String
  public let sample: URL?
  public init(id: String, title: String, author: String = "", sample: URL? = nil) {
    self.id = id
    self.title = title
    self.author = author
    self.sample = sample
  }
}
public struct ServiceError: LocalizedError, Sendable {
  public let status: Int
  public let message: String
  public var errorDescription: String? { message }
  public init(status: Int, message: String) {
    self.status = status
    self.message = message
  }
}
public struct FishClient: Sendable {
  public var token: String
  public var session: URLSession
  public init(token: String, session: URLSession = .shared) {
    self.token = token
    self.session = session
  }
  public static func voiceID(_ input: String) -> String? {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    let candidate: String
    if let url = URLComponents(string: trimmed), url.host != nil {
      guard url.host == "fish.audio" || url.host == "www.fish.audio", url.scheme == "https" else {
        return nil
      }
      candidate =
        url.queryItems?.first { $0.name == "modelId" }?.value ?? url.path.split(separator: "/").last
        .map(String.init) ?? ""
    } else {
      candidate = trimmed
    }
    guard candidate.range(of: "^[a-fA-F0-9]{32}$", options: .regularExpression) != nil else {
      return nil
    }
    return candidate.lowercased()
  }
  private func request(_ path: String, query: [URLQueryItem] = []) -> URLRequest {
    var components = URLComponents(string: "https://api.fish.audio" + path)!
    components.queryItems = query.isEmpty ? nil : query
    var request = URLRequest(url: components.url!)
    request.timeoutInterval = 45
    request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
    return request
  }
  private func checked(_ request: URLRequest) async throws -> Data {
    let (data, response) = try await session.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else {
      let message =
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
      throw ServiceError(status: status, message: message ?? "Fish Audio: errore HTTP \(status).")
    }
    return data
  }
  private func voice(_ object: [String: Any]) -> Voice? {
    guard let id = object["_id"] as? String, let title = object["title"] as? String else {
      return nil
    }
    let author = object["author"] as? [String: Any]
    let sample = (object["samples"] as? [[String: Any]])?.first?["audio"] as? String
    return Voice(
      id: id, title: title, author: author?["nickname"] as? String ?? "",
      sample: sample.flatMap(URL.init(string:)))
  }
  public func getVoice(_ id: String) async throws -> Voice {
    guard Self.voiceID(id) != nil else {
      throw ServiceError(status: 0, message: "Incolla un link Fish Audio o un ID voce valido.")
    }
    let data = try await checked(request("/model/" + id))
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let item = voice(object)
    else { throw AgentError.invalidReply }
    return item
  }
  public func voices(_ query: String, page: Int = 1) async throws -> (items: [Voice], more: Bool) {
    if let id = Self.voiceID(query) { return ([try await getVoice(id)], false) }
    let data = try await checked(
      request(
        "/model",
        query: [
          .init(name: "title", value: query), .init(name: "page_size", value: "30"),
          .init(name: "page_number", value: "\(max(1,page))"),
        ]))
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw AgentError.invalidReply
    }
    return (
      (object["items"] as? [[String: Any]] ?? []).compactMap(voice),
      object["has_more"] as? Bool ?? false
    )
  }
  public func speech(_ text: String, settings: Settings) async throws -> Data {
    var request = request("/v1/tts")
    request.httpMethod = "POST"
    request.timeoutInterval = 90
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "text": text, "reference_id": settings.fishVoiceID, "format": "mp3",
      "prosody": ["speed": min(2, max(0.5, settings.speechSpeed))],
    ])
    let model = settings.fishModel == "auto" ? "s2.1-pro" : settings.fishModel
    request.setValue(model, forHTTPHeaderField: "model")
    do { return try await checked(request) } catch let error as ServiceError
      where error.status == 402 && settings.fishModel == "auto"
    {
      request.setValue("s2.1-pro-free", forHTTPHeaderField: "model")
      return try await checked(request)
    }
  }
}
public enum LocalModels {
  public static func list(_ provider: Provider, session: URLSession = .shared) async throws
    -> [String]
  {
    guard provider.local else { return [] }
    let endpoint =
      provider == .ollama ? "http://127.0.0.1:11434/api/tags" : "http://127.0.0.1:1234/v1/models"
    var request = URLRequest(url: URL(string: endpoint)!)
    request.timeoutInterval = 5
    let (bytes, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200,
      let json = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
    else {
      throw ServiceError(
        status: 0,
        message:
          "Avvia \(provider == .ollama ? "Ollama" : "il server locale di LM Studio") e riprova.")
    }
    let models = json[provider == .ollama ? "models" : "data"] as? [[String: Any]] ?? []
    return models.compactMap { $0[provider == .ollama ? "name" : "id"] as? String }.sorted()
  }
}
