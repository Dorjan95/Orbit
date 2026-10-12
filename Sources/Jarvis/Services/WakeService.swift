import Foundation
import Speech
import AVFoundation

/// Hands-free activation: say "Hey Orbit" or clap twice (claps only
/// count while Orbit is idle, never while it talks or thinks). The mic stays open (macOS shows the orange dot) but nothing leaves
/// the Mac: the phrase is spotted by Apple's on-device recognizer, never the server one (without on-device support the
/// service stays off). Claps are found by an energy detector on the raw samples.
///
/// After the phrase (or the claps) the same recognizer keeps listening and captures the command: everything said after it, in one
/// breath or after a pause, until 1.5 s without new words. While Orbit talks, talking over it pauses it (see
/// `novelTail`). The Coordinator makes the service busy while Orbit thinks and stops it during push-to-talk,
/// which uses its own audio engine.
@MainActor
final class WakeService {
    enum Trigger: String { case name, clap, bargeIn, mascot }
    /// What counts as a start: the name (idle), the user's words over Orbit's (speaking), nothing (thinking).
    enum Mode: Equatable { case idle, speaking, busy }

    var onWake: ((Trigger) -> Void)?
    var onCaptureUpdate: ((String, Float) -> Void)?
    var onCommand: ((String, Trigger) -> Void)?
    var onNothingHeard: ((Trigger) -> Void)?
    private var trigger: Trigger = .name
    /// What Orbit is saying right now (without echo cancellation the mic hears it too).
    var echoText: () -> String = { "" }

    private(set) var isRunning = false
    /// Double clap as a second way to start (Settings switch).
    var clapEnabled = true { didSet { updateClaps() } }
    private(set) var capturing = false
    private(set) var mode: Mode = .idle
    private var restartedAt = Date()

    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var box: WakeTapBox?
    private var restartTimer: Task<Void, Never>?
    private var captureLoop: Task<Void, Never>?
    private var command = ""
    /// Pieces of the command Apple already closed or restarted from scratch after a pause (it does both).
    private var committed = ""
    private var lastPartial = ""
    /// How many words may come before the name for it to be the call (and be cut off) rather than part of the
    /// command: "Orbit" inside the request ("il nostro nuovo prodotto, Orbit") must stay in it.
    private var nameWithin = 3
    private var lastChange = Date()
    private var captureStart = Date()
    private var level: Float = 0
    private var loggedNoMic = false

    private(set) var echoCancelling = false
    private var sampleRate: Double = 48_000
    /// Sample index (in the tap's running count) where the current request's audio begins.
    private var requestStart = 0

    func start(locale: String, echoCancellation: Bool = false) {
        guard !isRunning else { return }
        guard SpeechService.micStatus == .authorized else {
            if !loggedNoMic { AppLog.write("wake: mic not authorized (\(SpeechService.micStatus.rawValue)), waiting"); loggedNoMic = true }
            return
        }
        loggedNoMic = false
        let r = SFSpeechRecognizer(locale: Locale(identifier: locale))
        guard r?.supportsOnDeviceRecognition == true, SpeechService.speechStatus == .authorized else {
            AppLog.write("wake: no on-device recognizer for \(locale), hands-free off")
            return
        }
        recognizer = r
        let input = engine.inputNode
        // Echo cancellation, so Orbit can be interrupted while it talks without hearing its own voice.
        // It changes the input format, so it goes on before the format is read.
        do { try input.setVoiceProcessingEnabled(echoCancellation) } catch { AppLog.write("wake: no echo cancellation \(error.localizedDescription)") }
        if input.isVoiceProcessingEnabled { input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min) }
        echoCancelling = input.isVoiceProcessingEnabled
        let format = input.outputFormat(forBus: 0)
        AppLog.write("wake: input \(format.sampleRate) Hz, \(format.channelCount) ch, echo cancellation=\(input.isVoiceProcessingEnabled)")
        guard format.sampleRate > 0 else { AppLog.write("wake: no mic signal"); return }
        sampleRate = format.sampleRate
        let b = WakeTapBox(sampleRate: format.sampleRate)
        b.onLevel = { [weak self] lv in self?.level = lv }
        b.onClap = { [weak self] in self?.clapHeard() }
        box = b
        updateClaps()
        input.removeTap(onBus: 0)
        Self.installTap(on: input, format: format, box: b)
        do { engine.prepare(); try engine.start() } catch { AppLog.write("wake: engine failed \(error.localizedDescription)"); return }
        isRunning = true
        restartRecognition()
        AppLog.write("wake: listening for \"Hey Orbit\"")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false; capturing = false
        captureLoop?.cancel(); restartTimer?.cancel()
        engine.inputNode.removeTap(onBus: 0); engine.stop()
        request?.endAudio(); task?.cancel(); task = nil; request = nil; box = nil
        AppLog.write("wake: stopped")
    }

    /// Each change of mode starts from a clean transcript, so nothing said before counts.
    func setMode(_ m: Mode) {
        guard m != mode, !capturing else { return }
        mode = m
        updateClaps()
        if isRunning, m != .busy { restartRecognition() }
    }

    /// Claps count only while Orbit is idle: its own voice or a sound it plays must never start it.
    private func updateClaps() { box?.clapsEnabled = clapEnabled && mode == .idle && !capturing }

    private func clapHeard() {
        guard isRunning, clapEnabled, mode == .idle, !capturing else { return }
        AppLog.write("wake: double clap")
        beginCapture(.clap, initial: "")
    }

    // MARK: Recognition

    /// `replayFrom`: a sample index to feed the new request from, so nothing said since then is lost.
    private func restartRecognition(replayFrom: Int? = nil) {
        request?.endAudio(); task?.cancel()
        restartedAt = Date()
        guard let recognizer else { request = nil; task = nil; _ = box?.attach(nil, replayFrom: nil); return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = true
        req.taskHint = .dictation
        req.contextualStrings = ["Hey Orbit", "Ehi Orbit"]
        request = req
        requestStart = box?.attach(req, replayFrom: replayFrom) ?? 0
        let start = requestStart, sr = sampleRate
        task = recognizer.recognitionTask(with: req) { [weak self] result, err in
            let text = result?.bestTranscription.formattedString
            let done = (result?.isFinal ?? false) || err != nil
            // Where the recognizer stopped listening: replay from there into the next request.
            let endSample: Int? = (result?.isFinal == true) ? result?.bestTranscription.segments.last.map { start + Int(($0.timestamp + $0.duration) * sr) } : nil
            if let err, (err as NSError).code != 1110 { let d = err.localizedDescription; Task { @MainActor in AppLog.write("wake: recognizer ended: \(d)") } }   // 1110 = no speech, every few seconds of quiet
            Task { @MainActor in
                guard let self, self.request === req else { return }
                if let text { self.heard(text) }
                if done {
                    let code = (err as NSError?)?.code ?? 0
                    if self.capturing { AppLog.write("wake: segment closed during capture (final=\(endSample != nil) err=\(code))") }
                    self.segmentEnded(replayFrom: endSample)
                }
            }
        }
        // Apple closes a recognition task after about a minute: start a fresh one before that.
        restartTimer?.cancel()
        restartTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(50))
            guard let self, !Task.isCancelled, self.isRunning, !self.capturing else { return }
            // Replay the last second so "Hey Orbit" at the switch is not cut in half.
            self.restartRecognition(replayFrom: (self.box?.totalSamples ?? 0) - Int(self.sampleRate))
        }
    }

    private func heard(_ text: String) {
        if capturing {
            // After "Hey Orbit" and a pause Apple often restarts the transcription without the phrase:
            // bank what we had and append the new text instead of losing it (the bug of 29/09).
            if Self.isRestart(from: lastPartial, to: text) { committed = Self.join(committed, Self.strip(lastPartial, within: nameWithin)); nameWithin = 3 }
            lastPartial = text
            let cmd = Self.join(committed, Self.strip(text, within: nameWithin))
            if cmd != command { command = cmd; lastChange = Date(); AppLog.write("wake: capture \"\(cmd)\"") }
            onCaptureUpdate?(command, level)
            return
        }
        switch mode {
        case .busy: return
        case .speaking:
            // Talking over Orbit. With echo cancellation any two words stop it; without, the mic also hears Orbit
            // itself, so only its name does, and the command starts clean after the name.
            if echoCancelling {
                guard text.split(separator: " ").count >= 2 || Self.commandAfterWakeWord(in: text) != nil else { return }
                beginCapture(.bargeIn, initial: Self.commandAfterWakeWord(in: text) ?? text)
            } else {
                // The mic hears Orbit too: words Orbit is not saying are the user's. Two in a row among the last
                // six words, or the name (when Orbit is not saying it), and it stops to listen.
                let spoken = echoText()
                let novel = Self.novelTail(heard: text, spoken: spoken)
                let named = Self.commandAfterWakeWord(in: text) != nil && Self.commandAfterWakeWord(in: spoken) == nil
                guard Date().timeIntervalSince(restartedAt) > 0.8, named || novel.count >= 2 else { return }
                AppLog.write("wake: talked over (\(named ? "name" : "\(novel.count) new words"))")
                beginCapture(.bargeIn, initial: named ? "" : novel.joined(separator: " "))
            }
        case .idle:
            // A fresh recognizer sometimes "hears" the name in the first instant of noise: ignore that instant.
            guard Date().timeIntervalSince(restartedAt) > 0.8, let cmd = Self.commandAfterWakeWord(in: text) else { return }
            AppLog.write("wake: name heard")
            // Words before the name in this transcript (room talk, "ok"): the name there is the call.
            nameWithin = max(3, Self.wordsBeforeLastName(in: text) + 1)
            beginCapture(.name, initial: cmd)
        }
    }

    private func segmentEnded(replayFrom: Int?) {
        guard isRunning else { return }
        if capturing {
            // Apple closed the segment after a pause: keep the words and keep listening; the silence timer decides the end.
            committed = Self.join(committed, Self.strip(lastPartial, within: nameWithin)); lastPartial = ""
            nameWithin = 3   // the next request starts after the name
            command = committed
        }
        restartRecognition(replayFrom: replayFrom)
    }

    // MARK: Capture

    /// Reuse the same silence detection and transcript flow for a desktop click.
    @discardableResult
    func captureFromMascot() -> Bool {
        guard isRunning, !capturing else { return false }
        beginCapture(.mascot, initial: "")
        return true
    }

    func finishFromMascot() { finishCapture() }

    private func beginCapture(_ trigger: Trigger, initial: String) {
        capturing = true
        self.trigger = trigger
        if trigger != .name { nameWithin = 3 }
        command = initial; committed = ""; lastPartial = ""; lastChange = Date(); captureStart = Date()
        restartTimer?.cancel()
        updateClaps()
        // After a clap the command is everything said next, from a clean transcript.
        if trigger == .clap || trigger == .mascot || (trigger == .bargeIn && !echoCancelling) { restartRecognition() }
        if trigger == .bargeIn && !echoCancelling { committed = initial }   // the words that interrupted it are the start of the command
        onWake?(trigger)
        captureLoop?.cancel()
        captureLoop = Task { @MainActor [weak self] in
            while let self, self.capturing, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, self.capturing else { return }
                let quiet = Date().timeIntervalSince(self.lastChange)
                let total = Date().timeIntervalSince(self.captureStart)
                let hasWords = !self.command.trimmingCharacters(in: .whitespaces).isEmpty
                self.onCaptureUpdate?(self.command, self.level)
                if (hasWords && quiet > 1.5) || (!hasWords && total > 6) || total > 30 { self.finishCapture(); return }
            }
        }
    }

    private func finishCapture() {
        guard capturing else { return }
        capturing = false
        captureLoop?.cancel()
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        command = ""; committed = ""; lastPartial = ""
        mode = .busy
        updateClaps()
        restartRecognition()
        AppLog.write("wake: command \"\(cmd)\"")
        if cmd.isEmpty { onNothingHeard?(trigger) } else { onCommand?(cmd, trigger) }
    }

    // MARK: Pure helpers (tested)

    /// The user's words in a transcript heard while Orbit talks: among the last six words, those of 4+ letters that
    /// are not (roughly) in what Orbit is saying. Not only a trailing run: when both talk, the recognizer interleaves
    /// the two voices. Short words are ignored because Orbit's own voice, misheard, turns into them
    /// ("Rossi Srl propone" → "cad pro", 29/09).
    nonisolated static func novelTail(heard: String, spoken: String) -> [String] {
        func words(_ s: String) -> [String] {
            s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "it_IT"))
                .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        }
        let said = Set(words(spoken))
        func known(_ w: String) -> Bool {
            if w.count <= 3 || w.contains(where: \.isNumber) { return true }   // short words and numbers prove nothing
            if said.contains(w) { return true }
            if said.contains(where: { $0.count > w.count && $0.contains(w) }) { return true }   // "mind" inside "mastermind"
            return said.contains { s in s.count >= 4 && w.count >= 4 && (s.hasPrefix(String(w.prefix(4))) || w.hasPrefix(String(s.prefix(4)))) }
        }
        return words(heard).suffix(6).filter { !known($0) }
    }

    /// Whether words heard over Orbit were really the user: three words or more, or a word that means "stop".
    /// Fewer (like "mind cioè", Orbit's own "Mastermind" misheard) and Orbit resumes talking.
    nonisolated static func isRealInterruption(_ cmd: String) -> Bool {
        let w = cmd.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "it_IT"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        let stops: Set<String> = ["basta", "stop", "ferma", "fermati", "aspetta", "zitto", "silenzio", "ok", "grazie", "no", "si", "scusa", "alt"]
        return commandAfterWakeWord(in: cmd) != nil || w.count >= 3 || w.contains { stops.contains($0) }
    }

    /// The part of a transcript that belongs to the command: after the name when the name opens it (at most
    /// `within` words before it), else all of it. A name later in the sentence is part of the request: cutting
    /// there threw away "crea un sito … del nostro nuovo prodotto Orbit" and left an empty command (29/09).
    nonisolated static func strip(_ text: String, within: Int = 3) -> String {
        let ns = text as NSString
        guard let re = try? NSRegularExpression(pattern: wakePattern, options: [.caseInsensitive]),
              let first = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              wordCount(ns.substring(to: first.range.location)) <= within else { return text.trimmingCharacters(in: .whitespaces) }
        return ns.substring(from: first.range.location + first.range.length).trimmingCharacters(in: .whitespaces)
    }

    nonisolated static func wordsBeforeLastName(in text: String) -> Int {
        let ns = text as NSString
        guard let re = try? NSRegularExpression(pattern: wakePattern, options: [.caseInsensitive]),
              let last = re.matches(in: text, range: NSRange(location: 0, length: ns.length)).last else { return 0 }
        return wordCount(ns.substring(to: last.range.location))
    }

    nonisolated private static func wordCount(_ s: String) -> Int {
        s.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.count
    }

    /// Apple dropped the old words and started over: the new partial is shorter and no longer begins the same way.
    /// (A normal partial only grows or revises its last words.)
    nonisolated static func isRestart(from old: String, to new: String) -> Bool {
        guard !old.isEmpty else { return false }
        return new.count < old.count && !new.lowercased().hasPrefix(String(old.lowercased().prefix(8)))
    }

    nonisolated static func join(_ a: String, _ b: String) -> String {
        let b = b.trimmingCharacters(in: .whitespaces)
        if a.isEmpty { return b }
        return b.isEmpty ? a : a + " " + b
    }

    // Italian dictation may transcribe the spoken "hey" as "ehi". Both require
    // the complete phrase; the app name alone must never be a wake phrase.
    nonisolated static let wakePattern = #"\b(?:hey|ehi)\b[\s,.!?:;]+(?:orbit|òrbit|órbit)\b[\s,.!?:;]*"#

    /// Text after the last complete "Hey Orbit", or nil if the phrase is absent.
    nonisolated static func commandAfterWakeWord(in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: wakePattern, options: [.caseInsensitive]) else { return nil }
        let ns = text as NSString
        guard let last = re.matches(in: text, range: NSRange(location: 0, length: ns.length)).last else { return nil }
        return ns.substring(from: last.range.location + last.range.length).trimmingCharacters(in: .whitespaces)
    }

    nonisolated private static func installTap(on input: AVAudioInputNode, format: AVAudioFormat, box: WakeTapBox) {
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in box.process(buffer) }
    }
}

/// Runs on the realtime audio thread: feeds the recognizer, the clap detector and the level meter.
final class WakeTapBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _request: SFSpeechAudioBufferRecognitionRequest?
    private var _clapsEnabled = false
    var clapsEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _clapsEnabled }
        set { lock.lock(); _clapsEnabled = newValue; lock.unlock() }
    }
    var onClap: (@MainActor () -> Void)?
    private var detector: ClapDetector
    var request: SFSpeechAudioBufferRecognitionRequest? {
        get { lock.lock(); defer { lock.unlock() }; return _request }
        set { lock.lock(); _request = newValue; lock.unlock() }
    }
    var onLevel: (@MainActor (Float) -> Void)?
    private var lastLevel = DispatchTime.now()
    /// The last ~3 s of audio, so a new recognition request can start from where the old one stopped listening:
    /// Apple closes a segment after a pause, and whatever was said before the next request opened was lost
    /// (a wake phrase followed by a pause used to yield an empty command).
    private var ring: [(start: Int, buffer: AVAudioPCMBuffer)] = []
    private var total = 0
    private let keep: Int
    var totalSamples: Int { lock.lock(); defer { lock.unlock() }; return total }

    /// Switch to a new request, first replaying what was heard since `from` (a sample index). Returns the sample
    /// index the new request's audio starts at (its time zero).
    func attach(_ req: SFSpeechAudioBufferRecognitionRequest?, replayFrom from: Int?) -> Int {
        lock.lock(); defer { lock.unlock() }
        var start = total
        if let req, let from {
            for e in ring where e.start + Int(e.buffer.frameLength) > from {
                if start == total { start = e.start }
                req.append(e.buffer)
            }
        }
        _request = req
        return start
    }
    /// With echo cancellation on, macOS hands the tap 9 channels; channel 0 is the cleaned voice and the only
    /// thing the recognizer can digest, so it gets a mono copy.
    private let mono: AVAudioFormat?

    init(sampleRate: Double) {
        mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)
        keep = Int(sampleRate * 3)
        detector = ClapDetector(sampleRate: sampleRate)
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        // Always a mono copy: the engine reuses its buffers, and the ring keeps them.
        guard let mono, let copy = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buffer.frameLength), let dst = copy.floatChannelData?[0] else { return }
        copy.frameLength = buffer.frameLength
        dst.update(from: ch, count: n)
        lock.lock()
        _request?.append(copy)
        ring.append((total, copy)); total += n
        while let first = ring.first, total - first.start > keep { ring.removeFirst() }
        lock.unlock()
        // The detector always runs, so its sense of the room noise stays current; it only fires when enabled.
        if detector.process(UnsafeBufferPointer(start: ch, count: n)), clapsEnabled { Task { @MainActor [onClap] in onClap?() } }
        let now = DispatchTime.now()
        if now.uptimeNanoseconds - lastLevel.uptimeNanoseconds > 50_000_000 {
            lastLevel = now
            var sum: Float = 0
            for i in 0..<n { sum += ch[i] * ch[i] }
            let lv = min(1, (n > 0 ? sqrt(sum / Float(n)) : 0) * 12)
            Task { @MainActor [onLevel] in onLevel?(lv) }
        }
    }
}

/// Two sharp, short bangs 0.15-0.7 s apart. A clap jumps at least 10x above the room noise within a 5 ms frame
/// and falls back under a quarter of its peak within 100 ms; speech, music and a slammed laptop lid mostly do not.
/// Conservative on purpose: a missed clap costs a second clap, a false one starts listening out of nowhere.
struct ClapDetector {
    let frameLen: Int
    let framesPerSecond: Double
    private var frame: [Float] = []
    private var frameIndex = 0
    private var background: Float = 0.003
    private var recent: [Float] = []           // last 8 frame RMS values (40 ms) before the current one
    private var pendingOnset: (index: Int, rms: Float)?
    private var lastClap: Int?
    private var refractoryUntil = 0

    init(sampleRate: Double) {
        frameLen = max(64, Int(sampleRate * 0.005))
        framesPerSecond = sampleRate / Double(max(64, Int(sampleRate * 0.005)))
        frame.reserveCapacity(frameLen)
    }

    /// Returns true when a double clap completes inside these samples.
    mutating func process<S: Sequence>(_ samples: S) -> Bool where S.Element == Float {
        var fired = false
        for x in samples {
            frame.append(x)
            if frame.count == frameLen {
                if step(frame) { fired = true }
                frame.removeAll(keepingCapacity: true)
            }
        }
        return fired
    }

    private mutating func step(_ f: [Float]) -> Bool {
        defer { frameIndex += 1 }
        var sum: Float = 0, peak: Float = 0
        for x in f { sum += x * x; peak = max(peak, abs(x)) }
        let rms = sqrt(sum / Float(f.count))
        let before = recent.isEmpty ? background : recent.reduce(0, +) / Float(recent.count)
        defer {
            recent.append(rms); if recent.count > 8 { recent.removeFirst() }
            if pendingOnset == nil { background = background * 0.995 + min(rms, background * 4) * 0.005 }
        }
        if let onset = pendingOnset {
            let age = frameIndex - onset.index
            if rms < onset.rms * 0.25 {
                pendingOnset = nil
                return confirmClap(at: onset.index)
            }
            if ms(age) > 100 { pendingOnset = nil }   // too long to be a clap
            return false
        }
        guard frameIndex >= refractoryUntil else { return false }
        if peak > 0.2, rms > 0.04, rms > background * 10, rms > before * 6 {
            pendingOnset = (frameIndex, rms)
        }
        return false
    }

    private func ms(_ frames: Int) -> Double { Double(frames) / framesPerSecond * 1000 }

    private mutating func confirmClap(at index: Int) -> Bool {
        if let prev = lastClap {
            let gap = ms(index - prev)
            if gap >= 150, gap <= 700 {
                lastClap = nil
                refractoryUntil = index + Int(1.5 * framesPerSecond)
                return true
            }
        }
        lastClap = index
        return false
    }
}
