@preconcurrency import AVFoundation
import OrbitCore
@preconcurrency import Speech
import XCTest

@testable import OrbitDesktop

@MainActor final class AudioCallbackTests: XCTestCase {
  func testCompletedSetupDoesNotHideMissingSystemPermissions() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      "orbit-audio-\(UUID())")
    defer { try? FileManager.default.removeItem(at: folder) }
    let controller = OrbitController(disk: DiskStore(folder: folder), importLegacy: false)
    controller.settings.configured = true
    controller.settings.handsFree = false
    let audio = AudioCoordinator(controller)
    controller.audio = audio
    defer { controller.shutdown() }
    audio.configure()
    XCTAssertEqual(controller.voiceNeedsPermission, !audio.granted)
    XCTAssertTrue(controller.settings.configured)
    XCTAssertFalse(audio.engine.isRunning)
  }
  func testWakeUsesAlternativeTranscriptionWithoutChangingCommandText() {
    let update = AudioCallbacks.RecognitionUpdate(
      text: "Ehi orbi", final: false, failed: false, alternatives: ["Ehi Orbit", "Ehi orbita"])
    XCTAssertEqual(update.wakeText, "Ehi Orbit")
    XCTAssertEqual(update.text, "Ehi orbi")
    XCTAssertNil(
      AudioCallbacks.RecognitionUpdate(
        text: "orbita", final: true, failed: false, alternatives: ["hey orbital"]
      ).wakeText)
  }
  func testPermissionCallbackCanArriveOnBackgroundQueue() async {
    for expected in [
      SFSpeechRecognizerAuthorizationStatus.authorized, .denied, .restricted, .notDetermined,
    ] {
      let status = await AudioCallbacks.speechAuthorization { completion in
        DispatchQueue.global().async {
          dispatchPrecondition(condition: .notOnQueue(.main))
          completion(expected)
        }
      }
      MainActor.assertIsolated()
      XCTAssertEqual(status, expected)
    }
  }

  func testRecognitionCallbackTransfersFailureBackToMainActor() async {
    let update: AudioCallbacks.RecognitionUpdate = await withCheckedContinuation { continuation in
      let callback = AudioCallbacks.recognition { update in
        MainActor.assertIsolated()
        continuation.resume(returning: update)
      }
      DispatchQueue.global().async {
        dispatchPrecondition(condition: .notOnQueue(.main))
        callback(nil, NSError(domain: "AudioCallbackTest", code: 1))
      }
    }
    XCTAssertNil(update.text)
    XCTAssertFalse(update.final)
    XCTAssertTrue(update.failed)
  }

  func testMicrophoneCallbackAcceptsBackgroundBuffersAndTransfersMeter() async {
    let request = SFSpeechAudioBufferRecognitionRequest()
    let energy: Float = await withCheckedContinuation { continuation in
      let callback = AudioCallbacks.microphone(request: request) { energy in
        MainActor.assertIsolated()
        continuation.resume(returning: energy)
      }
      DispatchQueue.global().async {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16)!
        buffer.frameLength = 16
        for i in 0..<16 { buffer.floatChannelData![0][i] = 0.25 }
        callback(buffer, AVAudioTime(sampleTime: 0, atRate: 16000))
      }
    }
    XCTAssertEqual(energy, 0.25, accuracy: 0.0001)
    request.endAudio()
  }
}
