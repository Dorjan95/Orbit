@preconcurrency import AVFoundation
@preconcurrency import Speech

/// Framework callbacks may arrive on arbitrary queues. Create them outside the main actor,
/// then transfer only value snapshots to the UI; never transfer framework result objects.
enum AudioCallbacks {
  struct RecognitionUpdate: Sendable {
    let text: String?
    let final: Bool
    let failed: Bool
  }

  nonisolated static func speechAuthorization(
    request:
      @Sendable (@escaping @Sendable (SFSpeechRecognizerAuthorizationStatus) -> Void) -> Void = {
        SFSpeechRecognizer.requestAuthorization($0)
      }
  ) async -> SFSpeechRecognizerAuthorizationStatus {
    await withCheckedContinuation { continuation in
      request { status in continuation.resume(returning: status) }
    }
  }

  nonisolated static func microphone(
    request: SFSpeechAudioBufferRecognitionRequest,
    receive: @escaping @MainActor @Sendable (Float) -> Void
  ) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
    { buffer, _ in
      request.append(buffer)
      let values = buffer.floatChannelData?[0]
      let count = Int(buffer.frameLength)
      var sum: Float = 0
      if let values, count > 0 {
        for i in 0..<count { sum += values[i] * values[i] }
      }
      let energy = count > 0 ? sqrt(sum / Float(count)) : 0
      Task { @MainActor in receive(energy) }
    }
  }

  nonisolated static func recognition(
    receive: @escaping @MainActor @Sendable (RecognitionUpdate) -> Void
  ) -> @Sendable (SFSpeechRecognitionResult?, (any Error)?) -> Void {
    { result, error in
      let update = RecognitionUpdate(
        text: result?.bestTranscription.formattedString,
        final: result?.isFinal ?? false, failed: error != nil)
      Task { @MainActor in receive(update) }
    }
  }
}
