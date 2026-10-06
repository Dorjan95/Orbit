@preconcurrency import AVFoundation
import Foundation

/// Use only voices actually exposed by Apple's public speech API. Never invent Siri identifiers.
@MainActor enum SystemVoices {
  static func available(language: String) -> [AVSpeechSynthesisVoice] {
    let prefix = language.split(separator: "-").first.map(String.init) ?? language
    return AVSpeechSynthesisVoice.speechVoices().filter {
      $0.language.split(separator: "-").first.map(String.init) == prefix
    }.sorted {
      if isSiri($0) != isSiri($1) { return isSiri($0) }
      if $0.quality != $1.quality { return $0.quality.rawValue > $1.quality.rawValue }
      return $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
  }
  static func isSiri(_ voice: AVSpeechSynthesisVoice) -> Bool {
    voice.identifier.lowercased().contains("siri") || voice.name.lowercased().contains("siri")
  }
  static func title(_ voice: AVSpeechSynthesisVoice) -> String {
    let quality =
      voice.quality == .premium ? " · Premium" : voice.quality == .enhanced ? " · Migliorata" : ""
    return (isSiri(voice) && !voice.name.lowercased().contains("siri") ? "Siri · " : "")
      + voice.name + quality + " · " + voice.language
  }
  static func resolve(_ identifier: String, language: String) -> AVSpeechSynthesisVoice? {
    selected(identifier) ?? AVSpeechSynthesisVoice(language: language)
  }
  static func selected(_ identifier: String) -> AVSpeechSynthesisVoice? {
    // Some macOS releases return a different default voice for an unknown identifier.
    guard !identifier.isEmpty, let voice = AVSpeechSynthesisVoice(identifier: identifier),
      voice.identifier == identifier
    else { return nil }
    return voice
  }
}
