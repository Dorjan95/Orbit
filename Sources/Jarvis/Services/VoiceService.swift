import Foundation
import AVFoundation
import Observation

/// §3.7 — Fish Audio TTS over HTTPS (model s2.1-pro), queued playback, barge-in,
/// and AVSpeechSynthesizer fallback so the app never goes silent.
@MainActor @Observable
final class VoiceService: NSObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    enum Mode { case fish, system }
    private(set) var isSpeaking = false
    private(set) var lastMode: Mode = .fish
    private(set) var lastError: String?
    var onFinished: (() -> Void)?
    /// Everything said since Orbit started talking, cues stripped: what the mic hears from the speakers,
    /// so the hands-free listener can tell Orbit's words from the user's.
    private(set) var echoText = ""

    private var player: AVAudioPlayer?
    private let synth = AVSpeechSynthesizer()
    private var queue: [String] = []
    private var settings: SettingsStore
    private var currentTask: Task<Void, Never>?
    /// Set once Fish answers 402 for the paid model; cleared on launch.
    private var proUnavailable = false

    init(settings: SettingsStore) {
        self.settings = settings
        super.init()
        synth.delegate = self
    }

    var hasFishKey: Bool { Secrets.get(Secrets.fishKey) != nil }

    /// Line used by the "hear it" buttons, in the dictation language.
    static func sample(_ s: Settings) -> String {
        s.isItalian ? "[excited] Ciao, eccomi. Dimmi pure cosa ti serve." : "[excited] Hi, I'm ready. What do you need?"
    }

    func speak(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        queue.append(t)
        if !isSpeaking { playNext() }
    }

    /// Talked over: hold the voice until we know it was really the user (see `WakeService.isRealInterruption`).
    private(set) var isPaused = false
    func pause() {
        guard isSpeaking, !isPaused else { return }
        isPaused = true
        player?.pause()
        if synth.isSpeaking { synth.pauseSpeaking(at: .immediate) }
    }
    /// A false alarm: carry on from where it stopped.
    func resume() {
        guard isPaused else { return }
        isPaused = false
        player?.play()
        if synth.isPaused { synth.continueSpeaking() }
    }

    /// Barge-in (§3.6): stop everything immediately.
    func stop() {
        isPaused = false
        queue.removeAll()
        currentTask?.cancel(); currentTask = nil
        player?.stop(); player = nil
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        if isSpeaking { isSpeaking = false; onFinished?() }
    }

    private func playNext() {
        guard !queue.isEmpty else { isSpeaking = false; onFinished?(); return }
        let text = queue.removeFirst()
        if !isSpeaking { echoText = "" }
        echoText += " " + Self.stripCues(text)
        isSpeaking = true
        currentTask = Task { [weak self] in
            guard let self else { return }
            if let key = Secrets.get(Secrets.fishKey) {
                do {
                    let pref = settings.settings.fishModel
                    var model = pref == "auto" ? (proUnavailable ? FishAudio.freeModel : FishAudio.model) : pref
                    var data: Data
                    do {
                        data = try await FishAudio.synthesize(text: text, apiKey: key, voiceID: settings.settings.fishVoiceID, speed: settings.settings.speakingRate, model: model)
                    } catch let e as FishAudio.APIError where e.status == 402 && pref == "auto" && model != FishAudio.freeModel {
                        AppLog.write("fish: no API credit for \(model) → using \(FishAudio.freeModel)")
                        proUnavailable = true; model = FishAudio.freeModel
                        data = try await FishAudio.synthesize(text: text, apiKey: key, voiceID: settings.settings.fishVoiceID, speed: settings.settings.speakingRate, model: model)
                    }
                    guard !Task.isCancelled else { return }
                    lastMode = .fish; lastError = nil
                    play(data: data)
                    return
                } catch {
                    lastError = "\(error)"
                    AppLog.write("fish tts failed: \(error)")
                }
            }
            guard !Task.isCancelled else { return }
            if Secrets.get(Secrets.fishKey) == nil { AppLog.write("fish: no key readable → system voice") }
            if settings.settings.systemVoiceFallback { speakWithSystem(text) } else { playNext() }
        }
    }

    private func play(data: Data) {
        do {
            let p = try AVAudioPlayer(data: data)
            p.delegate = self
            p.prepareToPlay()
            player = p
            if !isPaused { p.play() }
        } catch {
            lastError = "playback: \(error.localizedDescription)"
            speakWithSystem("")
        }
    }

    /// Fish Audio performs `[laughing]`-style cues; the system voice would read them literally, so drop them there.
    nonisolated static func stripCues(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s*\[[^\]]{1,30}\]\s*"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private func speakWithSystem(_ rawText: String) {
        let text = Self.stripCues(rawText)
        lastMode = .system
        guard !text.isEmpty else { playNext(); return }
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: settings.settings.speechLocale)
        u.rate = Float(0.5 * settings.settings.speakingRate)
        synth.speak(u)
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.playNext() }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.playNext() }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in if self.isSpeaking { self.playNext() } }
    }
}

/// Fish Audio REST client. Verified against https://api.fish.audio/openapi.json at build time.
enum FishAudio {
    static let base = URL(string: "https://api.fish.audio")!
    /// Own session: short timeouts so a dead socket fails fast instead of leaving the user waiting.
    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 12; c.timeoutIntervalForResource = 20
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()
    static let model = "s2.1-pro"       // "S2.1 Pro" — $15 / 1M chars of API credit
    static let freeModel = "s2.1-pro-free" // $0, verified working with zero API credit

    struct APIError: Error, CustomStringConvertible { let status: Int; let body: String; var description: String { "Fish \(status): \(body.prefix(120))" } }

    static func synthesize(text: String, apiKey: String, voiceID: String, speed: Double, model: String = model) async throws -> Data {
        var req = URLRequest(url: base.appendingPathComponent("v1/tts"))
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(model, forHTTPHeaderField: "model")
        let body: [String: Any] = ["text": text, "reference_id": voiceID, "format": "mp3", "mp3_bitrate": 128,
                                   "latency": "low", "normalize": true,
                                   "prosody": ["speed": speed, "volume": 0]]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        // Stale keep-alive sockets surface as -1005 / -1001 and succeed on retry (Fish makes the retry free).
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                let (data, resp) = try await session.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(code) else { throw APIError(status: code, body: String(data: data, encoding: .utf8) ?? "") }
                return data
            } catch let e as URLError where attempt < 2 && [.networkConnectionLost, .timedOut, .cannotConnectToHost, .notConnectedToInternet].contains(e.code) {
                lastError = e
                AppLog.write("fish tts retry \(attempt + 1) after \(e.code.rawValue)")
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        throw lastError ?? URLError(.unknown)
    }

    struct Balance: Sendable { let balance: Int; let total: Int; let type: String; let apiCreditUSD: String }

    static func balance(apiKey: String) async throws -> Balance {
        var req = URLRequest(url: base.appendingPathComponent("wallet/self/package"))
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200, let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError(status: code, body: String(data: data, encoding: .utf8) ?? "")
        }
        // The HTTP API bills the separate "API credit" (USD), not the package credits — fetch both.
        var api = "?"
        var r2 = URLRequest(url: base.appendingPathComponent("wallet/self/api-credit"))
        r2.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if let (d2, _) = try? await URLSession.shared.data(for: r2), let o2 = try? JSONSerialization.jsonObject(with: d2) as? [String: Any] {
            api = o2["credit"] as? String ?? "?"
        }
        return Balance(balance: (o["balance"] as? Int ?? 0) + (o["extra_balance"] as? Int ?? 0), total: o["total"] as? Int ?? 0, type: o["type"] as? String ?? "", apiCreditUSD: api)
    }

    struct Voice: Identifiable, Sendable, Hashable {
        let id: String
        let title: String
        let tags: [String]
        let author: String
        let languages: [String]
    }
    struct VoicePage: Sendable { let voices: [Voice]; let hasMore: Bool }
    enum VoiceInput: Equatable { case search(String), reference(String) }
    enum VoiceError: Error, LocalizedError {
        case invalidLink, unavailable, invalidResponse
        var errorDescription: String? {
            switch self {
            case .invalidLink: "Incolla il link della pagina di una voce Fish Audio oppure il suo ID di 32 caratteri."
            case .unavailable: "Questa voce non è disponibile per la sintesi tramite API. Scegli un'altra voce."
            case .invalidResponse: "Fish Audio ha restituito una risposta non valida. Riprova."
            }
        }
    }

    /// Pasted links are identifiers only: credentials always go to our fixed API host.
    static func voiceInput(_ input: String) throws -> VoiceInput {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        func isID(_ value: String) -> Bool {
            value.range(of: #"^[a-fA-F0-9]{32}$"#, options: .regularExpression) != nil
        }
        if isID(text) { return .reference(text.lowercased()) }
        let isLink = text.contains("://") || text.lowercased().hasPrefix("fish.audio/") || text.lowercased().hasPrefix("www.fish.audio/")
        guard isLink else { return .search(text) }
        let link = text.contains("://") ? text : "https://" + text
        guard let url = URLComponents(string: link), url.scheme?.lowercased() == "https",
              ["fish.audio", "www.fish.audio"].contains(url.host?.lowercased() ?? ""),
              url.user == nil, url.password == nil, url.port == nil else { throw VoiceError.invalidLink }
        let parts = url.path.split(separator: "/").map(String.init)
        if parts == ["app", "text-to-speech"] {
            let ids = (url.queryItems ?? []).filter { $0.name == "modelId" }.compactMap(\.value)
            guard ids.count == 1, isID(ids[0]) else { throw VoiceError.invalidLink }
            return .reference(ids[0].lowercased())
        }
        let prefixes = [["m"], ["app", "m"]]
        guard let id = parts.last, isID(id), prefixes.contains(Array(parts.dropLast())) else { throw VoiceError.invalidLink }
        return .reference(id.lowercased())
    }

    static func voiceSearchRequest(apiKey: String, query: String, language: String?, page: Int) -> URLRequest {
        var comps = URLComponents(url: base.appendingPathComponent("model"), resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "page_size", value: "50"), URLQueryItem(name: "page_number", value: String(max(1, page))), URLQueryItem(name: "sort_by", value: "score")]
        if let language, !language.isEmpty { items.append(URLQueryItem(name: "language", value: language)) }
        let title = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { items.append(URLQueryItem(name: "title", value: title)) }
        comps.queryItems = items
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return req
    }

    private static func voiceMetadata(_ object: [String: Any]) -> Voice? {
        guard let id = object["_id"] as? String, let title = object["title"] as? String,
              !id.isEmpty, !title.isEmpty, object["type"] as? String == "tts",
              object["state"] as? String == "trained", object["dmca_taken_down"] as? Bool != true else { return nil }
        return Voice(id: id, title: title, tags: Array((object["tags"] as? [String] ?? []).prefix(3)),
                     author: (object["author"] as? [String: Any])?["nickname"] as? String ?? "",
                     languages: object["languages"] as? [String] ?? [])
    }

    static func decodeVoicePage(_ data: Data, page: Int) throws -> VoicePage {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = object["items"] as? [[String: Any]] else { throw VoiceError.invalidResponse }
        let more = object["has_more"] as? Bool ?? ((object["total"] as? Int ?? 0) > page * 50)
        return VoicePage(voices: items.compactMap(voiceMetadata), hasMore: more && !items.isEmpty)
    }

    static func searchVoices(apiKey: String, query: String, language: String? = nil, page: Int = 1) async throws -> VoicePage {
        let req = voiceSearchRequest(apiKey: apiKey, query: query, language: language, page: page)
        let data = try await voiceData(for: req)
        return try decodeVoicePage(data, page: page)
    }

    static func voice(apiKey: String, id: String) async throws -> Voice {
        guard try voiceInput(id) == .reference(id.lowercased()) else { throw VoiceError.invalidLink }
        var req = URLRequest(url: base.appendingPathComponent("model").appendingPathComponent(id.lowercased()))
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return try decodeVoice(try await voiceData(for: req))
    }

    static func decodeVoice(_ data: Data) throws -> Voice {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw VoiceError.invalidResponse }
        guard let voice = voiceMetadata(object) else { throw VoiceError.unavailable }
        return voice
    }

    private static func voiceData(for request: URLRequest) async throws -> Data {
        let (data, resp) = try await session.data(for: request)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw APIError(status: code, body: String(data: data, encoding: .utf8) ?? "") }
        return data
    }

    static func voiceErrorMessage(_ error: Error) -> String {
        if let e = error as? APIError {
            switch e.status {
            case 401: return "La chiave Fish Audio non è valida. Controllala nella sezione qui sopra."
            case 403: return "Questa voce non è accessibile con la tua chiave API. Verifica l'account e la visibilità della voce su Fish Audio."
            case 404: return "Voce non trovata. Controlla il link: potrebbe essere stata rimossa o resa privata."
            case 429: return "Troppe richieste a Fish Audio. Attendi qualche secondo e riprova."
            default: return "Fish Audio non risponde (errore \(e.status)). Riprova tra poco."
            }
        }
        if let e = error as? VoiceError { return e.localizedDescription }
        return "Non riesco a cercare le voci. Controlla la connessione e riprova."
    }
}
