import Foundation

enum CodexProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case openai, ollama, lmstudio
    var id: String { rawValue }
    var isLocal: Bool { self != .openai }
    var title: String {
        switch self { case .openai: "OpenAI · ChatGPT"; case .ollama: "Ollama · locale"; case .lmstudio: "LM Studio · locale" }
    }
    var serverName: String { self == .ollama ? "Ollama" : "LM Studio" }
    var modelsURL: URL? {
        switch self {
        case .openai: nil
        case .ollama: URL(string: "http://127.0.0.1:11434/api/tags")
        case .lmstudio: URL(string: "http://127.0.0.1:1234/v1/models")
        }
    }
}

/// Stored independently for the voice assistant and project workers. Switching
/// providers retains each provider's selected model.
struct CodexModelSelection: Codable, Equatable, Sendable {
    var provider: CodexProvider = .openai
    var ollamaModel: String = ""
    var lmStudioModel: String = ""
    var includeIntegrations: Bool = false

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decodeIfPresent(CodexProvider.self, forKey: .provider) ?? .openai
        ollamaModel = try c.decodeIfPresent(String.self, forKey: .ollamaModel) ?? ""
        lmStudioModel = try c.decodeIfPresent(String.self, forKey: .lmStudioModel) ?? ""
        includeIntegrations = try c.decodeIfPresent(Bool.self, forKey: .includeIntegrations) ?? false
    }

    var localModel: String {
        get { provider == .ollama ? ollamaModel : lmStudioModel }
        set { if provider == .ollama { ollamaModel = newValue } else { lmStudioModel = newValue } }
    }

    func backend(cloudModel: String) -> CodexBackend {
        CodexBackend(provider: provider, model: provider.isLocal ? localModel : cloudModel, includeIntegrations: includeIntegrations)
    }
}

/// A session snapshots this configuration so follow-ups keep their original
/// model and provider, even when global settings change in the meantime.
struct CodexBackend: Codable, Hashable, Sendable {
    var provider: CodexProvider = .openai
    var model: String = ""
    var includeIntegrations: Bool = false

    init(provider: CodexProvider = .openai, model: String = "", includeIntegrations: Bool = false) {
        self.provider = provider; self.model = model; self.includeIntegrations = includeIntegrations
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decodeIfPresent(CodexProvider.self, forKey: .provider) ?? .openai
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        includeIntegrations = try c.decodeIfPresent(Bool.self, forKey: .includeIntegrations) ?? false
    }
    var workerIsolationArguments: [String] {
        provider.isLocal && !includeIntegrations
            ? ["--ignore-user-config", "-c", "features.apps=false", "-c", "features.plugins=false", "-c", "web_search=\"disabled\""] : []
    }
    var cleanModel: String { model.trimmingCharacters(in: .whitespacesAndNewlines) }
    var configurationError: String? {
        provider.isLocal && cleanModel.isEmpty
            ? "Scegli un modello di \(provider.serverName) in Impostazioni → Modelli." : nil
    }
    var arguments: [String] {
        var args = provider.isLocal ? ["--oss", "--local-provider", provider.rawValue]
            : ["-c", "model_provider=\"openai\""]
        if provider.isLocal {
            args += ["-c", "model_context_window=16384", "-c", "model_auto_compact_token_limit=12000"]
        }
        if !cleanModel.isEmpty { args += ["--model", cleanModel] }
        return args
    }
    var label: String { provider.isLocal ? provider.serverName : "OpenAI" }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func resumeCommand(executable: String, sessionID: String) -> String {
        ([executable] + arguments + workerIsolationArguments + ["resume", sessionID]).map(Self.shellQuote).joined(separator: " ")
    }
}

enum LocalModelError: LocalizedError {
    case unavailable(String), invalidResponse, http(Int)
    var errorDescription: String? {
        switch self {
        case .unavailable(let name): "Avvia \(name) e il suo server locale, poi premi Ricontrolla."
        case .invalidResponse: "Il server ha restituito un elenco di modelli non valido."
        case .http(let status): "Il server locale ha risposto con errore HTTP \(status)."
        }
    }
}

/// Discovery only contacts the provider's standard loopback endpoint. It never
/// downloads models or changes a user's server configuration.
enum LocalModelService {
    static func models(provider: CodexProvider) async throws -> [String] {
        guard let url = provider.modelsURL else { return [] }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 8
        config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(from: url) }
        catch is CancellationError { throw CancellationError() }
        catch { throw LocalModelError.unavailable(provider.serverName) }
        guard let http = response as? HTTPURLResponse else { throw LocalModelError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw LocalModelError.http(http.statusCode) }
        return try parse(data, provider: provider)
    }

    static func parse(_ data: Data, provider: CodexProvider) throws -> [String] {
        struct OllamaList: Decodable { struct Model: Decodable { let name: String }; let models: [Model] }
        struct StudioList: Decodable { struct Model: Decodable { let id: String }; let data: [Model] }
        let names: [String]
        do {
            switch provider {
            case .openai: return []
            case .ollama: names = try JSONDecoder().decode(OllamaList.self, from: data).models.map(\.name)
            case .lmstudio: names = try JSONDecoder().decode(StudioList.self, from: data).data.map(\.id)
            }
        } catch { throw LocalModelError.invalidResponse }
        return Array(Set(names.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })).sorted()
    }
}
