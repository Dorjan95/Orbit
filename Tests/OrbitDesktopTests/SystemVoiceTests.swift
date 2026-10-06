@preconcurrency import AVFoundation
import OrbitCore
import XCTest

@testable import OrbitDesktop

@MainActor final class SystemVoiceTests: XCTestCase {
  func testSystemVoiceBypassesFishWithSavedCredential() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      "orbit-voice-\(UUID())")
    defer { try? FileManager.default.removeItem(at: folder) }
    let disk = DiskStore(folder: folder)
    try disk.setCredential("fixture-key")
    let controller = OrbitController(disk: disk, importLegacy: false)
    controller.settings.handsFree = false
    controller.settings.speechProvider = .system
    let voice = SystemVoices.available(language: "it-IT").first
    controller.settings.systemVoiceID = voice?.identifier ?? ""
    var fishCalls = 0
    var spoken: AVSpeechUtterance?
    let audio = AudioCoordinator(
      controller,
      fishSpeech: { _, _, _ in
        fishCalls += 1
        throw ServiceError(status: 500, message: "Fixture")
      }, systemSpeech: { spoken = $0 })
    defer {
      audio.stop()
      controller.shutdown()
    }
    audio.say("Ciao Orbit")
    await audio.speechTask?.value
    XCTAssertEqual(fishCalls, 0)
    XCTAssertEqual(spoken?.speechString, "Ciao Orbit")
    XCTAssertEqual(
      spoken?.voice?.identifier,
      SystemVoices.resolve(controller.settings.systemVoiceID, language: "it-IT")?.identifier)
    XCTAssertEqual(disk.credential(), "fixture-key")
  }

  func testFishFailureRespectsFallbackAndChosenAppleVoice() async throws {
    for fallback in [true, false] {
      let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
        "orbit-voice-\(UUID())")
      defer { try? FileManager.default.removeItem(at: folder) }
      let disk = DiskStore(folder: folder)
      try disk.setCredential("fixture-key")
      let controller = OrbitController(disk: disk, importLegacy: false)
      controller.settings.handsFree = false
      controller.settings.speechProvider = .fish
      controller.settings.systemFallback = fallback
      controller.settings.systemVoiceID =
        SystemVoices.available(language: "it-IT").last?.identifier ?? ""
      var fishCalls = 0
      var spoken: AVSpeechUtterance?
      let audio = AudioCoordinator(
        controller,
        fishSpeech: { _, _, _ in
          fishCalls += 1
          throw ServiceError(status: 503, message: "Fixture")
        }, systemSpeech: { spoken = $0 })
      defer {
        audio.stop()
        controller.shutdown()
      }
      audio.say("Risposta")
      await audio.speechTask?.value
      XCTAssertEqual(fishCalls, 1)
      XCTAssertEqual(spoken != nil, fallback)
      if fallback {
        XCTAssertEqual(
          spoken?.voice?.identifier,
          SystemVoices.resolve(controller.settings.systemVoiceID, language: "it-IT")?.identifier)
      } else {
        XCTAssertFalse(audio.speaking)
      }
    }
  }

  func testExistingSettingsKeepFishAndSystemChoicePersists() throws {
    var settings = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
    XCTAssertEqual(settings.speechProvider, .fish)
    XCTAssertEqual(settings.systemVoiceID, "")
    settings.speechProvider = .system
    settings.systemVoiceID = "saved-apple-voice"
    let saved = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
    XCTAssertEqual(saved.speechProvider, .system)
    XCTAssertEqual(saved.systemVoiceID, "saved-apple-voice")
    XCTAssertEqual(
      SystemVoices.resolve("unavailable-voice", language: "it-IT")?.identifier,
      AVSpeechSynthesisVoice(language: "it-IT")?.identifier)
  }
}
