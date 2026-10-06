@preconcurrency import AVFoundation
import AppKit
import OrbitCore
@preconcurrency import Speech

@MainActor
final class AudioCoordinator: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
  weak var controller: OrbitController?
  let engine = AVAudioEngine()
  let synthesizer = AVSpeechSynthesizer()
  var player: AVAudioPlayer?
  var recognizer: SFSpeechRecognizer?
  var request: SFSpeechAudioBufferRecognitionRequest?
  var recognition: SFSpeechRecognitionTask?
  var speechTask: Task<Void, Never>?
  var quietTask: Task<Void, Never>?
  var renewal: Task<Void, Never>?
  var speaking = false
  private var recognitionID = UUID()
  private var tapInstalled = false
  private var recording = false
  private var command = ""
  private var previousWake = ""
  private var lastClap = Date.distantPast
  private var lastPeak = Date.distantPast
  private var lastLoud = false
  private var waitingSpeech: [(text: String, state: MascotState)] = []
  init(_ controller: OrbitController) {
    self.controller = controller
    super.init()
    synthesizer.delegate = self
  }
  var granted: Bool {
    SFSpeechRecognizer.authorizationStatus() == .authorized
      && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
  }
  func permissions() async {
    let speech = await AudioCallbacks.speechAuthorization()
    let mic = await AVCaptureDevice.requestAccess(for: .audio)
    guard let controller else { return }
    if speech == .authorized && mic {
      controller.settings.configured = true
      configure()
      controller.error = nil
    } else {
      controller.error =
        "Consenti Microfono e Riconoscimento vocale in Impostazioni di Sistema → Privacy e sicurezza, poi riapri Orbit."
    }
  }
  func configure() {
    guard let controller else { return }
    if granted && controller.settings.configured && (controller.settings.handsFree || recording)
      && (!speaking || controller.settings.interruption)
    {
      startRecognition()
    } else {
      endRecognition()
    }
  }
  func startRecognition() {
    guard recognition == nil, let controller else { return }
    let recognizer = SFSpeechRecognizer(locale: Locale(identifier: controller.settings.language))
    guard let recognizer, recognizer.isAvailable else {
      controller.error = "Il riconoscimento vocale non è disponibile per questa lingua."
      return
    }
    self.recognizer = recognizer
    let token = UUID()
    recognitionID = token
    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
    self.request = request
    let node = engine.inputNode
    let format = node.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else {
      controller.error = "Non è disponibile un microfono."
      return
    }
    node.installTap(
      onBus: 0, bufferSize: 1024, format: format,
      block: AudioCallbacks.microphone(request: request) { [weak self] energy in
        if self?.recognitionID == token { self?.meter(energy) }
      })
    tapInstalled = true
    recognition = recognizer.recognitionTask(
      with: request,
      resultHandler: AudioCallbacks.recognition { [weak self] update in
        guard let self, self.recognitionID == token else { return }
        if let text = update.text { self.receive(text, final: update.final) }
        guard self.recognitionID == token else { return }
        if update.failed || update.final {
          self.endRecognition()
          self.renewal?.cancel()
          self.renewal = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.configure()
          }
        }
      })
    do {
      engine.prepare()
      try engine.start()
    } catch {
      controller.error = error.localizedDescription
      endRecognition()
    }
    renewal?.cancel()
    renewal = Task { [weak self] in
      try? await Task.sleep(for: .seconds(45))
      guard !Task.isCancelled, let self, !recording else { return }
      endRecognition()
      configure()
    }
  }
  func endRecognition() {
    recognitionID = UUID()
    renewal?.cancel()
    engine.stop()
    if tapInstalled {
      engine.inputNode.removeTap(onBus: 0)
      tapInstalled = false
    }
    request?.endAudio()
    recognition?.cancel()
    recognition = nil
    request = nil
  }
  func beginCommand() {
    guard let controller else { return }
    guard granted else {
      Task {
        await permissions()
        if granted { beginCommand() }
      }
      return
    }
    stopSpeaking()
    quietTask?.cancel()
    endRecognition()
    command = ""
    previousWake = ""
    recording = true
    controller.isListening = true
    controller.transcript = ""
    controller.setPhase(.listening, replay: true)
    if controller.settings.sound { NSSound(named: "Pop")?.play() }
    startRecognition()
    if !GlobalShortcuts.isHolding {
      quietTask = Task { [weak self] in
        try? await Task.sleep(for: .seconds(15))
        guard !Task.isCancelled else { return }
        self?.finishCommand()
      }
    }
  }
  func receive(_ text: String, final: Bool) {
    guard let controller else { return }
    if recording {
      command = WakePhrase.command(in: text) ?? text
      controller.transcript = command
      quietTask?.cancel()
      // Voice-activated commands submit after silence; a held shortcut submits on release.
      if !GlobalShortcuts.isHolding {
        quietTask = Task { [weak self] in
          try? await Task.sleep(for: .seconds(final ? 0.3 : 1.6))
          guard !Task.isCancelled else { return }
          self?.finishCommand()
        }
      }
    } else if controller.settings.handsFree, let tail = WakePhrase.command(in: text),
      text != previousWake
    {
      previousWake = text
      if speaking && !controller.settings.interruption { return }
      beginCommand()
      if !tail.isEmpty {
        command = tail
        controller.transcript = tail
        quietTask = Task { [weak self] in
          try? await Task.sleep(for: .seconds(1.6))
          guard !Task.isCancelled else { return }
          self?.finishCommand()
        }
      }
    }
  }
  func meter(_ rms: Float) {
    guard let controller, controller.settings.claps, !recording, !speaking else { return }
    let loud = rms > 0.16
    let now = Date()
    if loud && !lastLoud && now.timeIntervalSince(lastPeak) > 0.12 {
      if now.timeIntervalSince(lastClap) > 0.18 && now.timeIntervalSince(lastClap) < 0.75 {
        lastClap = .distantPast
        beginCommand()
      } else {
        lastClap = now
      }
      lastPeak = now
    }
    lastLoud = loud
  }
  func finishCommand() {
    guard recording, let controller else { return }
    let text = command
    recording = false
    quietTask?.cancel()
    controller.isListening = false
    endRecognition()
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      controller.phase = .ready
      configure()
      flush()
    } else {
      controller.submit(text)
      configure()
    }
  }
  func cancelCommand() {
    recording = false
    quietTask?.cancel()
    controller?.isListening = false
    endRecognition()
    configure()
  }
  func say(_ text: String, announcement: Bool = false, state: MascotState = .responding) {
    guard let controller, !text.isEmpty else { return }
    if announcement && (recording || controller.isInterpreting || speaking) {
      waitingSpeech.append((text, state))
      return
    }
    stopSpeaking()
    controller.setPhase(state)
    speaking = true
    configure()
    let settings = controller.settings
    let key = controller.disk.credential()
    speechTask = Task { [weak self] in
      guard let self else { return }
      if let key, !key.isEmpty {
        do {
          let data = try await FishClient(token: key).speech(text, settings: settings)
          guard !Task.isCancelled else { return }
          let player = try AVAudioPlayer(data: data)
          self.player = player
          player.delegate = self
          player.prepareToPlay()
          guard player.play() else {
            throw ServiceError(status: 0, message: "Impossibile riprodurre la risposta vocale.")
          }
          return
        } catch {
          guard !Task.isCancelled else { return }
          controller.error = "Voce Fish Audio: \(error.localizedDescription)"
          if !settings.systemFallback {
            finishedSpeaking()
            return
          }
        }
      }
      guard !Task.isCancelled else { return }
      let utterance = AVSpeechUtterance(string: text)
      utterance.voice = AVSpeechSynthesisVoice(language: settings.language)
      utterance.rate = Float(min(0.6, max(0.25, settings.speechSpeed * 0.46)))
      synthesizer.speak(utterance)
    }
  }
  func stopSpeaking() {
    speechTask?.cancel()
    player?.stop()
    player = nil
    synthesizer.stopSpeaking(at: .immediate)
    speaking = false
  }
  func finishedSpeaking() {
    speaking = false
    player = nil
    configure()
    controller?.rest(after: 1)
    flush()
  }
  func flush() {
    guard !speaking, !recording, controller?.isInterpreting == false, !waitingSpeech.isEmpty else {
      return
    }
    let item = waitingSpeech.removeFirst()
    say(item.text, announcement: true, state: item.state)
  }
  func stop() {
    waitingSpeech = []
    stopSpeaking()
    quietTask?.cancel()
    endRecognition()
  }
  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
  ) { Task { @MainActor [weak self] in self?.finishedSpeaking() } }
  nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    Task { @MainActor [weak self] in self?.finishedSpeaking() }
  }
}
