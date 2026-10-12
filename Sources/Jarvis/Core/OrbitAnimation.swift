import Foundation
import Observation

enum OrbitPose: String, CaseIterable, Sendable {
    case idle, greeting, listening, thinking, speaking, working, success, clarify, error, dragging

    var atlas: String {
        switch self { case .idle, .dragging: "greeting"; default: rawValue }
    }
    var columns: Int { 4 }
    var rows: Int { 4 }
    var frameCount: Int { columns * rows }
    var fps: Double { self == .thinking ? 10 : 12 }
    var stillFrame: Int { self == .listening || self == .thinking ? frameCount - 1 : 0 }

    struct FrameSample: Equatable {
        let current: Int
        let next: Int
        let blend: Double
    }

    /// Blend adjacent poses without changing the speed or duplicating endpoints at a loop turn.
    func sample(elapsed: TimeInterval, moving: Bool) -> FrameSample {
        guard moving, self != .idle, self != .dragging else { return FrameSample(current: stillFrame, next: stillFrame, blend: 0) }
        let position = max(0, elapsed) * fps
        let tick = Int(position)
        // Keep the pose crisp, then briefly ease into the next one. A full-frame
        // dissolve would leave two helmets visible throughout a fast jump.
        let transition = max(0, (position - Double(tick) - 0.65) / 0.35)
        let blend = transition * transition * (3 - 2 * transition)
        return FrameSample(current: index(at: tick), next: index(at: tick + 1),
                           blend: blend)
    }

    var label: String {
        switch self {
        case .idle: "Riposo"
        case .greeting: "Saluto"
        case .listening: "Ascolto"
        case .thinking: "Ragionamento"
        case .speaking: "Risposta"
        case .working: "Lavoro"
        case .success: "Successo"
        case .clarify: "Domanda"
        case .error: "Problema"
        case .dragging: "Spostamento"
        }
    }

    func frameIndex(elapsed: TimeInterval, moving: Bool) -> Int {
        guard moving, self != .idle, self != .dragging else { return stillFrame }
        let tick = Int(max(0, elapsed) * fps)
        return index(at: tick)
    }

    private func index(at tick: Int) -> Int {
        if self == .greeting || self == .listening || self == .thinking { return min(tick, frameCount - 1) }
        if self == .success { return tick % frameCount }
        let period = 2 * (frameCount - 1)
        let position = tick % period
        return position < frameCount ? position : period - position
    }

    func message(runningCount: Int) -> String {
        switch self {
        case .idle: "Cliccami per parlare"
        case .greeting: "Ciao! Sono pronto."
        case .listening: "Dimmi tutto,\nti sto ascoltando"
        case .thinking: "Ci sto pensando…"
        case .speaking: "Ecco cosa ho da dirti"
        case .working: runningCount > 1 ? "\(runningCount) lavori in corso" : "Mi metto al lavoro"
        case .success: "Fatto!"
        case .clarify: "Ho una domanda per te"
        case .error: "Qualcosa non va"
        case .dragging: "Spostami dove vuoi"
        }
    }
}

@MainActor @Observable
final class OrbitAnimationModel {
    var displayed = false
    var dragging = false
    private(set) var reaction: OrbitPose?
    private(set) var reactionStarted = Date()
    private var reactionEnds = Date.distantPast
    private(set) var listeningStarted: Date?
    private(set) var thinkingStarted: Date?
    private var playbackPose: OrbitPose?
    private var playbackStarted = Date()
    let epoch = Date()

    /// Transcript/level updates must not replay the clip. Only a new capture starts it.
    func syncListening(active: Bool, at date: Date = Date()) {
        if active {
            if listeningStarted == nil { listeningStarted = date }
        } else {
            listeningStarted = nil
        }
    }

    /// Status updates preserve playback; a new reasoning turn replays the clip.
    func syncThinking(active: Bool, at date: Date = Date()) {
        if active {
            if thinkingStarted == nil { thinkingStarted = date }
        } else {
            thinkingStarted = nil
        }
    }

    func react(_ pose: OrbitPose, at date: Date = Date(), duration: TimeInterval? = nil) {
        reaction = pose
        reactionStarted = date
        reactionEnds = date.addingTimeInterval(duration ?? (pose == .greeting ? 1.6 : 2.8))
    }

    func syncPlayback(pose: OrbitPose, at date: Date = Date()) {
        guard playbackPose != pose else { return }
        playbackPose = pose
        playbackStarted = date
    }

    func pose(pillVisible: Bool, pillState: PillState, runningCount: Int, pendingCount: Int, at date: Date) -> OrbitPose {
        if dragging { return .dragging }
        if pillVisible {
            switch pillState {
            case .listening: return .listening
            case .thinking: return .thinking
            case .clarify: return .clarify
            case .error: return .error
            case .speaking:
                if date < reactionEnds, reaction == .success { return .success }
                return .speaking
            }
        }
        if date < reactionEnds, let reaction { return reaction }
        if pendingCount > 0 { return .clarify }
        return runningCount > 0 ? .working : .idle
    }

    func elapsed(for pose: OrbitPose, at date: Date) -> TimeInterval {
        if pose == .listening { return max(0, date.timeIntervalSince(listeningStarted ?? date)) }
        if pose == .thinking { return max(0, date.timeIntervalSince(thinkingStarted ?? date)) }
        if pose == reaction { return max(0, date.timeIntervalSince(reactionStarted)) }
        guard playbackPose == pose else { return 0 }
        return max(0, date.timeIntervalSince(playbackStarted))
    }
}
