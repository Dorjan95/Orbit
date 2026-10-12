import Foundation
import Speech
import AVFoundation
import Observation

/// §3.5 — on-device push-to-talk STT via SFSpeechRecognizer (requiresOnDeviceRecognition = true).
/// No audio leaves the machine.
@MainActor @Observable
final class SpeechService {
    private(set) var transcript = ""
    private(set) var level: Float = 0          // 0…1 mic level for the pulsing dot
    private(set) var error: String?
    private(set) var isListening = false

    private let engine = AVAudioEngine()
    private var recognizer = SFSpeechRecognizer(locale: Locale(identifier: "it-IT"))
    private var localeID = "it-IT"
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var finalContinuation: CheckedContinuation<String, Never>?
    private var lastPartial = ""
    /// Text from recognition segments Apple has already closed (it finalises after pauses / ~1 min); the live partial is appended to this.
    private var committed = ""
    private var tapBox: TapBox?

    static var micStatus: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }
    static var speechStatus: SFSpeechRecognizerAuthorizationStatus { SFSpeechRecognizer.authorizationStatus() }

    /// The TCC callback arrives on an arbitrary queue; hop through a nonisolated continuation so no actor state is touched there.
    nonisolated static func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in c.resume(returning: status == .authorized) }
        }
    }

    static func requestPermissions() async -> (mic: Bool, speech: Bool) {
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        let speech = await requestSpeechAuthorization()
        return (mic, speech)
    }

    func start(locale: String = "it-IT") {
        guard !isListening else { return }
        if locale != localeID {
            recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale))
            localeID = locale
        }
        transcript = ""; lastPartial = ""; committed = ""; error = nil; level = 0
        if Self.micStatus == .notDetermined || Self.speechStatus == .notDetermined {
            error = "Consenti microfono e riconoscimento vocale, poi riprova"
            Task { _ = await Self.requestPermissions() }
            return
        }
        guard Self.micStatus == .authorized else { error = "Il microfono è bloccato: Impostazioni di Sistema › Privacy"; return }
        guard Self.speechStatus == .authorized else { error = "Il riconoscimento vocale è spento: Impostazioni di Sistema › Privacy"; return }
        guard let recognizer, recognizer.isAvailable else { error = "Riconoscimento vocale non disponibile per questa lingua"; return }

        let req = makeRequest(recognizer)
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { error = "Nessun segnale dal microfono"; return }
        input.removeTap(onBus: 0)
        let box = TapBox(request: req)
        tapBox = box
        Self.installTap(on: input, format: format, box: box)
        box.onLevel = { [weak self] lv in self?.level = self.map { $0.level * 0.6 + lv * 0.4 } ?? lv }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            self.error = "Il microfono non parte: \(error.localizedDescription)"; return
        }
        isListening = true
        startRecognition(recognizer, req)
    }

    private func makeRequest(_ recognizer: SFSpeechRecognizer) -> SFSpeechAudioBufferRecognitionRequest {
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        req.taskHint = .dictation
        req.contextualStrings = ["Hey Orbit", "Ehi Orbit", "Orbit"]
        request = req
        return req
    }

    private func startRecognition(_ recognizer: SFSpeechRecognizer, _ req: SFSpeechAudioBufferRecognitionRequest) {
        task = recognizer.recognitionTask(with: req) { [weak self] result, err in
            // Delivered on an arbitrary queue — extract plain values before hopping to the main actor.
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = err != nil
            Task { @MainActor in
                guard let self, self.request === req else { return }   // ignore callbacks from a superseded segment
                if let text { self.absorb(partial: text) }
                if isFinal || failed {
                    if self.isListening {
                        // Apple closed the segment mid-hold: bank it and keep listening with a fresh request.
                        self.commitPartial()
                        let next = self.makeRequest(recognizer)
                        self.tapBox?.request = next
                        self.startRecognition(recognizer, next)
                    } else {
                        self.deliverFinal()
                    }
                }
            }
        }
    }

    /// Merge a partial result into the running transcript. Apple occasionally restarts `bestTranscription` from scratch
    /// after a pause without sending isFinal; detect that (new text is short and not an extension) and bank the old partial.
    private func absorb(partial text: String) {
        if !lastPartial.isEmpty, text.count < lastPartial.count / 2, !lastPartial.lowercased().hasPrefix(text.lowercased().prefix(12)) {
            commitPartial()
        }
        lastPartial = text
        transcript = Self.join(committed, text)
    }

    private func commitPartial() {
        committed = Self.join(committed, lastPartial)
        lastPartial = ""
        transcript = committed
    }

    private static func join(_ a: String, _ b: String) -> String {
        let b = b.trimmingCharacters(in: .whitespaces)
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a + " " + b
    }

    /// Stop capturing and wait (briefly) for the final transcript.
    func stop() async -> String {
        guard isListening else { return transcript }
        isListening = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        request?.endAudio()
        let text = await withCheckedContinuation { (c: CheckedContinuation<String, Never>) in
            finalContinuation = c
            // Never wait more than 1.2 s for the recognizer to finalise.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(1200))
                self?.deliverFinal()
            }
        }
        task?.cancel(); task = nil; request = nil
        level = 0
        return text
    }

    /// Explicitly nonisolated: the tap block runs on the realtime audio thread and must not be main-actor-isolated.
    nonisolated private static func installTap(on input: AVAudioInputNode, format: AVAudioFormat, box: TapBox) {
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            box.request.append(buffer)
            guard let ch = buffer.floatChannelData?[0] else { return }
            let n = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<n { sum += ch[i] * ch[i] }
            box.publish(min(1, (n > 0 ? sqrt(sum / Float(n)) : 0) * 12))
        }
    }

    private func deliverFinal() {
        guard let c = finalContinuation else { return }
        finalContinuation = nil
        c.resume(returning: Self.join(committed, lastPartial))
    }

    func cancel() {
        isListening = false; committed = ""; lastPartial = ""
        engine.inputNode.removeTap(onBus: 0); engine.stop()
        request?.endAudio(); task?.cancel(); task = nil; request = nil
        finalContinuation?.resume(returning: ""); finalContinuation = nil
        level = 0
    }
}


/// Bridges the realtime audio tap to the main actor: holds the recognition request
/// (safe to append from any thread) and throttles level updates to ~20 Hz.
final class TapBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _request: SFSpeechAudioBufferRecognitionRequest
    var request: SFSpeechAudioBufferRecognitionRequest {
        get { lock.lock(); defer { lock.unlock() }; return _request }
        set { lock.lock(); _request = newValue; lock.unlock() }
    }
    var onLevel: (@MainActor (Float) -> Void)?
    private var last = DispatchTime.now()
    init(request: SFSpeechAudioBufferRecognitionRequest) { self._request = request }
    func publish(_ lv: Float) {
        let now = DispatchTime.now()
        guard now.uptimeNanoseconds - last.uptimeNanoseconds > 50_000_000 else { return }
        last = now
        Task { @MainActor [onLevel] in onLevel?(lv) }
    }
}
