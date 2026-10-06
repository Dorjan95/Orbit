import Foundation

/// Lossless protocol values, including server request IDs. Never persist live requests or answers.
public enum JSONValue: Codable, Hashable, Sendable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])
  public init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() {
      self = .null
    } else if let v = try? c.decode(Bool.self) {
      self = .bool(v)
    } else if let v = try? c.decode(String.self) {
      self = .string(v)
    } else if let v = try? c.decode(Double.self) {
      self = .number(v)
    } else if let v = try? c.decode([JSONValue].self) {
      self = .array(v)
    } else {
      self = .object(try c.decode([String: JSONValue].self))
    }
  }
  public func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .null: try c.encodeNil()
    case .bool(let v): try c.encode(v)
    case .number(let v): try c.encode(v)
    case .string(let v): try c.encode(v)
    case .array(let v): try c.encode(v)
    case .object(let v): try c.encode(v)
    }
  }
  public subscript(_ key: String) -> JSONValue { object[key] ?? .null }
  public var object: [String: JSONValue] { if case .object(let v) = self { v } else { [:] } }
  public var array: [JSONValue] { if case .array(let v) = self { v } else { [] } }
  public var string: String? { if case .string(let v) = self { v } else { nil } }
  public var number: Double? { if case .number(let v) = self { v } else { nil } }
  public var bool: Bool? { if case .bool(let v) = self { v } else { nil } }
  public var json: String {
    String(decoding: (try? JSONEncoder().encode(self)) ?? Data(), as: UTF8.self)
  }
}
extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
  ExpressibleByBooleanLiteral, ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral
{
  public init(stringLiteral value: String) { self = .string(value) }
  public init(integerLiteral value: Int) { self = .number(Double(value)) }
  public init(booleanLiteral value: Bool) { self = .bool(value) }
  public init(dictionaryLiteral elements: (String, JSONValue)...) {
    self = .object(Dictionary(uniqueKeysWithValues: elements))
  }
  public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

public struct ToolIntegration: Identifiable, Equatable, Sendable {
  public var id: String { name }
  public let name: String
  public let auth: String
  public let tools: [String]
  public var status: String
  public var error: String?
  public init(_ value: JSONValue) {
    name = value["name"].string ?? "MCP"
    auth = value["authStatus"].string ?? "unknown"
    tools = value["tools"].object.keys.sorted()
    status =
      value["runtimeStatus"].string ?? value["runtimeStatus"]["state"].string ?? value[
        "runtimeStatus"]["type"].string ?? ""
    error = value["toolsError"].string ?? value["runtimeStatus"]["error"].string
  }
}
public struct PromptQuestion: Identifiable, Equatable, Sendable {
  public let id: String
  public let title: String
  public let secret: Bool
  public let options: [String]
  public let descriptions: [String]
}
public struct AgentPrompt: Identifiable, Equatable, Sendable {
  public enum Kind: Sendable { case command, files, permissions, questions, form, url, unsupported }
  public let id: JSONValue
  public let method: String
  public let params: JSONValue
  public let kind: Kind
  public let title: String
  public let details: String
  public let questions: [PromptQuestion]
  public var url: URL? {
    guard kind == .url, let raw = params["url"].string, let url = URL(string: raw),
      ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.user == nil,
      url.password == nil
    else { return nil }
    return url
  }
  public var canAccept: Bool {
    if kind == .unsupported { return false }
    if kind == .questions {
      let ids = questions.map(\.id)
      return !ids.isEmpty && !ids.contains("") && Set(ids).count == ids.count
    }
    if kind == .url { return url != nil }
    if kind == .command, !params["availableDecisions"].array.isEmpty {
      return params["availableDecisions"].array.contains("accept")
    }
    if kind == .form { return FormSchema.supported(params["requestedSchema"]) }
    return true
  }
  public init(id: JSONValue, method: String, params: JSONValue, filePreview: String = "") {
    self.id = id
    self.method = method
    self.params = params
    questions = params["questions"].array.map {
      PromptQuestion(
        id: $0["id"].string ?? "", title: $0["question"].string ?? "",
        secret: $0["isSecret"].bool ?? false,
        options: $0["options"].array.compactMap { $0["label"].string },
        descriptions: $0["options"].array.compactMap { $0["description"].string })
    }
    switch method {
    case "item/commandExecution/requestApproval":
      kind = .command
      title =
        params["kind"].string == "writeStdin"
        ? "Autorizza l’input al terminale" : "Autorizza il comando"
    case "item/fileChange/requestApproval":
      kind = .files
      title = "Autorizza le modifiche"
    case "item/permissions/requestApproval":
      kind = .permissions
      title = "Permessi per questo lavoro"
    case "item/tool/requestUserInput":
      kind = .questions
      title = "Codex ti chiede"
    case "mcpServer/elicitation/request":
      switch params["mode"].string {
      case "form", "openai/form", "openaiForm": kind = .form
      case "url": kind = .url
      default: kind = .unsupported
      }
      title = "Richiesta di \(params["serverName"].string ?? "MCP")"
    default:
      kind = .unsupported
      title = "Richiesta non supportata"
    }
    var pieces = [
      params["reason"].string, params["message"].string, params["command"].string,
      params["cwd"].string.map { "Cartella: " + $0 },
      params["grantRoot"].string.map { "Accesso: " + $0 },
    ].compactMap { $0 }
    for key in ["networkApprovalContext", "additionalPermissions", "permissions"]
    where params[key] != .null {
      pieces.append(params[key].json)
    }
    if !filePreview.isEmpty { pieces.append(filePreview) }
    if kind == .unsupported {
      pieces.append(
        "Questa richiesta richiede un client Codex compatibile. Puoi annullarla o aprire la sessione nel terminale."
      )
    }
    details = pieces.joined(separator: "\n\n")
  }
  public func response(accept: Bool, answers: [String: String] = [:], form: JSONValue = [:]) throws
    -> JSONValue
  {
    if !accept {
      switch kind {
      case .command, .files:
        let decisions = params["availableDecisions"].array
        return [
          "decision": decisions.isEmpty || decisions.contains("decline") ? "decline" : "cancel"
        ]
      case .permissions: return ["permissions": [:], "scope": "turn"]
      case .questions:
        return [
          "answers": .object(
            questions.reduce(into: [String: JSONValue]()) { $0[$1.id] = ["answers": []] })
        ]
      default: return ["action": "decline", "content": .null]
      }
    }
    guard canAccept else {
      throw AgentError.execution("Questa richiesta non può essere approvata da Orbit.")
    }
    switch kind {
    case .command, .files: return ["decision": "accept"]
    case .permissions: return ["permissions": params["permissions"], "scope": "turn"]
    case .questions:
      var values: [String: JSONValue] = [:]
      for question in questions {
        guard let text = answers[question.id],
          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
          throw AgentError.execution("Rispondi a tutte le domande prima di inviare.")
        }
        values[question.id] = ["answers": [.string(text)]]
      }
      return ["answers": .object(values)]
    case .form:
      try FormSchema.validate(form, schema: params["requestedSchema"])
      return ["action": "accept", "content": form]
    case .url: return ["action": "accept", "content": .null]
    case .unsupported: throw AgentError.execution("Richiesta non supportata.")
    }
  }
}
/// Only advertise forms we can actually validate. Unsupported schemas stay declinable.
public enum FormSchema {
  public static func supported(_ schema: JSONValue) -> Bool {
    guard schema["type"].string == "object" else { return false }
    return schema["properties"].object.values.allSatisfy {
      guard let type = $0["type"].string else { return false }
      if type == "array" {
        return $0["items"]["type"].string == "string" || !$0["items"]["anyOf"].array.isEmpty
      }
      return ["string", "boolean", "integer", "number"].contains(type)
    }
  }
  public static func validate(_ value: JSONValue, schema: JSONValue) throws {
    func fail(_ field: String) -> AgentError {
      .execution("Controlla il campo «\(field)»: valore non valido o mancante.")
    }
    guard supported(schema), case .object(let fields) = value else { throw fail("modulo") }
    let properties = schema["properties"].object
    for name in schema["required"].array.compactMap(\.string) where fields[name] == nil {
      throw fail(name)
    }
    for (name, v) in fields {
      guard let rule = properties[name] else { throw fail(name) }
      let choices =
        rule["enum"].array.isEmpty ? rule["oneOf"].array.map { $0["const"] } : rule["enum"].array
      if !choices.isEmpty, !choices.contains(v) { throw fail(name) }
      switch rule["type"].string {
      case "string":
        guard let text = v.string else { throw fail(name) }
        if let min = rule["minLength"].number, Double(text.count) < min { throw fail(name) }
        if let max = rule["maxLength"].number, Double(text.count) > max { throw fail(name) }
        switch rule["format"].string {
        case "email": if !text.contains("@") || text.contains(" ") { throw fail(name) }
        case "uri": if URL(string: text)?.scheme == nil { throw fail(name) }
        case "date":
          if text.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) == nil {
            throw fail(name)
          }
        case "date-time": if ISO8601DateFormatter().date(from: text) == nil { throw fail(name) }
        default: break
        }
      case "boolean": if v.bool == nil { throw fail(name) }
      case "number", "integer":
        guard let n = v.number, n.isFinite else { throw fail(name) }
        if rule["type"].string == "integer", n.rounded() != n { throw fail(name) }
        if let min = rule["minimum"].number, n < min { throw fail(name) }
        if let max = rule["maximum"].number, n > max { throw fail(name) }
      case "array":
        guard case .array(let items) = v, items.allSatisfy({ $0.string != nil }) else {
          throw fail(name)
        }
        if let min = rule["minItems"].number, Double(items.count) < min { throw fail(name) }
        if let max = rule["maxItems"].number, Double(items.count) > max { throw fail(name) }
        let allowed =
          rule["items"]["enum"].array.isEmpty
          ? rule["items"]["anyOf"].array.map { $0["const"] } : rule["items"]["enum"].array
        if !allowed.isEmpty, !items.allSatisfy({ allowed.contains($0) }) { throw fail(name) }
      default: throw fail(name)
      }
    }
  }
}
