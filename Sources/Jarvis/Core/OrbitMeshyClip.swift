import Foundation

/// Only animations present in the user's Meshy download. Names are source IDs.
enum OrbitMeshyClip: String, CaseIterable, Codable, Sendable {
    case running = "Running"
    case walking = "Walking"
    case bigWave = "Big_Wave_Hello"
    case heart = "Big_Heart_Gesture"
    case excitedWalk = "Excited_Walk_F"
    case dancing = "FunnyDancing_03"
    case runFast = "RunFast"
    case falling = "Shot_and_Slow_Fall_Backward"
    case crossLegged = "Sit_Cross_Legged_on_Floor"
    case sitTransition = "Stand_to_Sit_Transition_M"
    case wave = "Wave_One_Hand"
    case situps = "situps"

    var label: String {
        switch self {
        case .running: "Corsa"
        case .walking: "Camminata"
        case .bigWave: "Saluto ampio"
        case .heart: "Gesto del cuore"
        case .excitedWalk: "Camminata entusiasta"
        case .dancing: "Danza"
        case .runFast: "Corsa veloce"
        case .falling: "Caduta all’indietro"
        case .crossLegged: "Seduto a gambe incrociate"
        case .sitTransition: "Da in piedi a seduto"
        case .wave: "Saluto con una mano"
        case .situps: "Addominali"
        }
    }

    /// Durations in original 24 fps frames; checked against the supplied GLB.
    var duration: TimeInterval {
        let frames: Double
        switch self {
        case .running: frames = 16
        case .walking: frames = 25
        case .bigWave: frames = 128
        case .heart: frames = 149
        case .excitedWalk: frames = 234
        case .dancing: frames = 192
        case .runFast: frames = 12
        case .falling: frames = 106
        case .crossLegged: frames = 60
        case .sitTransition: frames = 114
        case .wave: frames = 99
        case .situps: frames = 55
        }
        return frames / 24
    }

    var canLoop: Bool { self == .walking || self == .running || self == .runFast }
}

extension OrbitPose {
    var defaultMeshyClip: OrbitMeshyClip? {
        switch self {
        case .greeting: .bigWave
        case .listening: .sitTransition
        case .thinking: .crossLegged
        case .working: .walking
        case .success: .dancing
        default: nil
        }
    }
    static let configurableAnimations: [OrbitPose] = [.greeting, .listening, .thinking, .speaking, .working, .success, .clarify, .error]

    func meshClip(assignments: [String: String]) -> OrbitMeshyClip? {
        guard let id = assignments[rawValue] else { return defaultMeshyClip }
        if id == "standing" { return nil }
        return OrbitMeshyClip(rawValue: id) ?? defaultMeshyClip
    }
}

extension Settings {
    func meshClip(for pose: OrbitPose) -> OrbitMeshyClip? {
        pose.meshClip(assignments: mascotClipAssignments)
    }
    func mascotReactionDuration(for pose: OrbitPose) -> TimeInterval {
        meshClip(for: pose)?.duration ?? 2.8
    }
}
