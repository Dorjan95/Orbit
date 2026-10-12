import Foundation

/// JSON-RPC IDs are opaque; a server's numeric 1 is distinct from its string "1".
enum AgentRequestID: Codable, Hashable, Sendable {
    case number(Int64), string(String)
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let number = try? c.decode(Int64.self) { self = .number(number) }
        else { self = .string(try c.decode(String.self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .number(let n): try c.encode(n); case .string(let s): try c.encode(s) }
    }
    var wireValue: Any { switch self { case .number(let n): n; case .string(let s): s } }
    static func parse(_ value: Any?) -> Self? {
        guard let value, let data = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

struct ApprovalOption: Codable, Hashable, Sendable, Identifiable {
    var optionID: String
    var name: String
    var kind: String
    var id: String { optionID }
    var isOneShot: Bool { kind == "allow_once" || kind == "reject_once" }
    var isTransient: Bool { isOneShot || kind == "allow_turn" }
    var label: String { kind == "allow_once" ? "Consenti una volta" : kind == "allow_turn" ? "Consenti per questo turno" : kind == "reject_once" ? "Rifiuta" : name }
    enum CodingKeys: String, CodingKey { case optionID = "optionId", name, kind }
}

enum ApprovalState: String, Codable, Sendable { case pending, decided, cancelled, expired }

/// A decision is journaled before sending it. Recovery never replays a grant.
struct AgentApproval: Codable, Hashable, Sendable, Identifiable {
    var id: UUID = UUID()
    var requestID: AgentRequestID
    var remoteSessionID: String
    var toolCallID: String
    var title: String
    var details: String
    var options: [ApprovalOption]
    var turnID: UUID?
    var state: ApprovalState = .pending
    var selectedOptionID: String?
    var createdAt: Date = Date()
    var decidedAt: Date?
}
