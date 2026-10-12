import Foundation
import Security
import LocalAuthentication
import CryptoKit
import Observation

enum AgentUsageError: Error, Sendable {
    case unavailable, timeout, authentication, keychainLocked, expired, response, customProvider, usagePermission
    var message: String {
        switch self {
        case .unavailable: "CLI non disponibile"
        case .timeout: "Aggiornamento non riuscito: tempo scaduto"
        case .authentication: "Accedi nuovamente dalla CLI"
        case .keychainLocked: "Portachiavi non accessibile"
        case .expired: "Accesso Claude scaduto: apri Claude Code"
        case .response: "Quote non disponibili: riprova più tardi"
        case .customProvider: "Quote non disponibili con questo provider"
        case .usagePermission: "Abilita l’accesso alle quote"
        }
    }
}

@MainActor @Observable final class AgentUsageStore {
    var codex: AgentUsageSnapshot?
    var claude: AgentUsageSnapshot?
    var codexError: String?
    var claudeNeedsQuotaPermission = false
    var claudeError: String?
    private(set) var refreshing = false
    let enabled: Bool
    init(enabled: Bool) { self.enabled = enabled }
    func refresh(codexPath: String?, claudePath: String?) async {
        guard enabled, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        async let codexResult = AgentUsageService.codex(executable: codexPath)
        async let claudeResult = AgentUsageService.claude(executable: claudePath)
        switch await codexResult {
        case .success(let snapshot): codex = snapshot; codexError = nil
        case .failure(let error): codexError = error.message
        }
        switch await claudeResult {
        case .success(let snapshot): claude = snapshot; claudeError = nil; claudeNeedsQuotaPermission = false
        case .failure(let error): claudeError = error.message; claudeNeedsQuotaPermission = error == .usagePermission
        }
    }
}

enum AgentUsageService {
    /// A separate, short-lived RPC connection: no threads, prompts or inference.
    @MainActor static func codex(executable: String?) async -> Result<AgentUsageSnapshot, AgentUsageError> {
        guard let executable else { return .failure(.unavailable) }
        return await CodexQuotaConnection().read(executable: executable)
    }

    static func claude(executable: String?) async -> Result<AgentUsageSnapshot, AgentUsageError> {
        guard executable != nil else { return .failure(.unavailable) }
        let environment = CLILocator.childEnvironment
        guard environment["ANTHROPIC_BASE_URL"] == nil, environment["CLAUDE_CODE_USE_BEDROCK"] != "1",
              environment["CLAUDE_CODE_USE_VERTEX"] != "1", environment["CLAUDE_CODE_USE_FOUNDRY"] != "1",
              environment["CLAUDE_CODE_CUSTOM_OAUTH_URL"] == nil, environment["ANTHROPIC_AUTH_TOKEN"] == nil,
              environment["CLAUDE_CODE_OAUTH_TOKEN"] == nil else { return .failure(.customProvider) }
        // Reuse the CLI's existing login in memory. Never persist, log or refresh credentials.
        let credential = await Task.detached { claudeCredential(environment: environment) }.value
        guard case .success(let token) = credential else {
            if case .failure(let error) = credential { return .failure(error) }
            return .failure(.authentication)
        }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.httpMethod = "GET"; request.timeoutInterval = 12
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCache = nil
        let session = URLSession(configuration: config, delegate: QuotaRedirectGuard(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failure(.response) }
            if http.statusCode == 401 { return .failure(.authentication) }
            if http.statusCode == 403 { return .failure(.usagePermission) }
            guard http.statusCode == 200, let snapshot = AgentUsageParser.claude(data) else { return .failure(.response) }
            return .success(snapshot)
        } catch { return .failure(.response) }
    }

    private static func claudeCredential(environment: [String: String]) -> Result<String, AgentUsageError> {
        let directory = environment["CLAUDE_CONFIG_DIR"] ?? NSHomeDirectory() + "/.claude"
        let suffix = environment["CLAUDE_CONFIG_DIR"].map { _ in
            "-" + SHA256.hash(data: Data(directory.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        } ?? ""
        let context = LAContext(); context.interactionNotAllowed = true
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials" + suffix,
            kSecAttrAccount as String: NSUserName(),
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        var data = status == errSecSuccess ? item as? Data : nil
        // The CLI's file storage fallback, only when no keychain item exists.
        if status == errSecItemNotFound {
            data = try? Data(contentsOf: URL(fileURLWithPath: directory).appendingPathComponent(".credentials.json"))
        }
        guard let data else { return .failure(status == errSecInteractionNotAllowed || status == errSecAuthFailed ? .keychainLocked : .authentication) }
        return claudeToken(from: data)
    }

    static func claudeToken(from data: Data, now: Date = Date()) -> Result<String, AgentUsageError> {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any], let token = oauth["accessToken"] as? String, !token.isEmpty else {
            return .failure(.authentication)
        }
        if let scopes = oauth["scopes"] as? [String], !scopes.contains("user:profile") { return .failure(.usagePermission) }
        if let expiry = oauth["expiresAt"] as? Double, expiry / 1000 <= now.timeIntervalSince1970 { return .failure(.expired) }
        return .success(token)
    }
}

private final class QuotaRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

@MainActor private final class CodexQuotaConnection {
    private var process: Subprocess?
    func read(executable: String) async -> Result<AgentUsageSnapshot, AgentUsageError> {
        do {
            let child = try Subprocess(executable: executable, arguments: ["app-server"], cwd: NSHomeDirectory(), environment: CLILocator.childEnvironment, interactiveInput: true)
            process = child
            let (stream, continuation) = AsyncStream<String>.makeStream()
            child.onLine = { continuation.yield($0) }
            child.onExit = { _ in continuation.finish() }
            child.start()
            let timeout = Task { try? await Task.sleep(for: .seconds(15)); if !Task.isCancelled { child.kill(); continuation.finish() } }
            defer { timeout.cancel(); child.closeInput(); child.kill(); continuation.finish(); process = nil }
            send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "orbit_usage", "version": "0.1"], "capabilities": ["experimentalApi": false]]], child)
            for await line in stream {
                if Task.isCancelled { return .failure(.timeout) }
                guard let frame = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let id = frame["id"] as? Int else { continue }
                if let error = frame["error"] as? [String: Any] {
                    return .failure((error["code"] as? Int) == -32601 ? .response : .authentication)
                }
                if id == 1 {
                    send(["method": "initialized"], child)
                    send(["id": 2, "method": "account/rateLimits/read"], child)
                } else if id == 2, let result = frame["result"], let data = try? JSONSerialization.data(withJSONObject: result), let snapshot = AgentUsageParser.codex(data) {
                    return .success(snapshot)
                } else if id == 2 { return .failure(.response) }
            }
            return .failure(.timeout)
        } catch { return .failure(.unavailable) }
    }
    private func send(_ frame: [String: Any], _ child: Subprocess) {
        guard var data = try? JSONSerialization.data(withJSONObject: frame) else { return }
        data.append(10); child.send(data) { error in if error != nil { child.kill() } }
    }
}
