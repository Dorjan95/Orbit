import AppKit
import RealityKit
import SwiftUI
import simd

/// All motion is sampled explicitly: pause, scrubbing and the held listening pose
/// never depend on a looping animation player's clock.
@MainActor final class OrbitMeshyMotion {
    struct Framing: Decodable {
        let verticalTan: Double
        let horizontalTan: Double

        func fieldOfView(aspect: Double) -> Float {
            Float(2 * atan(max(verticalTan, horizontalTan / max(0.1, aspect))) * 180 / .pi)
        }
    }
    struct Clip {
        let duration: TimeInterval
        let frames: [[Transform]]
        let framing: Framing
    }
    private struct Stored: Decodable {
        let schemaVersion: Int
        let fps: Double
        let jointNames: [String]
        let clips: [String: StoredClip]
        let sourceSHA256: String
    }
    private struct StoredClip: Decodable {
        let duration: Double
        let frames: [[[Float]]]
        let framing: Framing
    }
    enum AssetError: Error { case missingResource, invalidMotion, missingSkeleton, incompatibleSkeleton }
    let jointNames: [String]
    let clips: [String: Clip]
    let fps: Double
    let sourceSHA256: String

    init(url: URL) throws {
        let stored = try JSONDecoder().decode(Stored.self, from: Data(contentsOf: url))
        guard stored.schemaVersion == 1, stored.fps == 24, stored.jointNames.count == 28,
              Set(stored.jointNames).count == 28 else { throw AssetError.invalidMotion }
        fps = stored.fps
        jointNames = stored.jointNames
        sourceSHA256 = stored.sourceSHA256
        var converted: [String: Clip] = [:]
        for (name, clip) in stored.clips {
            guard clip.duration.isFinite, clip.duration > 0,
                  clip.framing.verticalTan.isFinite, clip.framing.horizontalTan.isFinite,
                  clip.framing.verticalTan > 0, clip.framing.horizontalTan > 0,
                  clip.frames.count == Int((clip.duration * fps).rounded()) + 1 else { throw AssetError.invalidMotion }
            let frames = try clip.frames.map { frame in
                guard frame.count == stored.jointNames.count else { throw AssetError.invalidMotion }
                return try frame.map { values -> Transform in
                    guard values.count == 10, values.allSatisfy(\.isFinite),
                          values[7...9].allSatisfy({ $0 > 0 }) else { throw AssetError.invalidMotion }
                    let q = SIMD4<Float>(values[3], values[4], values[5], values[6])
                    guard abs(simd_length(q) - 1) < 0.01 else { throw AssetError.invalidMotion }
                    return Transform(scale: [values[7], values[8], values[9]],
                        rotation: simd_quatf(vector: simd_normalize(q)),
                        translation: [values[0], values[1], values[2]])
                }
            }
            converted[name] = Clip(duration: clip.duration, frames: frames, framing: clip.framing)
        }
        guard Set(converted.keys) == Set(OrbitMeshyClip.allCases.map(\.rawValue)) else { throw AssetError.invalidMotion }
        clips = converted
    }

    func sample(pose: OrbitPose, elapsed: TimeInterval, moving: Bool,
                clip: OrbitMeshyClip? = nil, useDefault: Bool = true) -> [Transform] {
        let selected = useDefault ? pose.defaultMeshyClip : clip
        guard let selected else { return clips[OrbitMeshyClip.wave.rawValue]!.frames[0] }
        if !moving, pose == .working, selected.canLoop { return clips[selected.rawValue]!.frames[0] }
        return sample(clip: selected, elapsed: elapsed, moving: moving,
                      looping: pose == .working && selected.canLoop)
    }

    /// Native motion, sampled without changing its key poses or speed. Preview
    /// is single-pass; only authored locomotion loops may cycle during work.
    func sample(clip selected: OrbitMeshyClip, elapsed: TimeInterval, moving: Bool,
                looping: Bool = false) -> [Transform] {
        let clip = clips[selected.rawValue]!
        let safeTime = elapsed.isFinite ? max(0, elapsed) : 0
        let t: TimeInterval
        if !moving { t = clip.duration }
        else if looping && selected.canLoop { t = safeTime.truncatingRemainder(dividingBy: clip.duration) }
        else { t = min(clip.duration, safeTime) }
        let position = t * fps
        let a = min(Int(position), clip.frames.count - 1)
        let b = min(a + 1, clip.frames.count - 1)
        return Self.blend(clip.frames[a], clip.frames[b], Float(position - Double(a)))
    }

    static func blend(_ a: [Transform], _ b: [Transform], _ amount: Float) -> [Transform] {
        zip(a, b).map { from, to in
            Transform(scale: simd_mix(from.scale, to.scale, SIMD3(repeating: amount)),
                rotation: simd_slerp(from.rotation, to.rotation, amount),
                translation: simd_mix(from.translation, to.translation, SIMD3(repeating: amount)))
        }
    }
}

@MainActor final class OrbitMeshyRig {
    private static var cached: (Entity, OrbitMeshyMotion)?
    private static var unavailable = false
    let root: Entity
    let skin: ModelEntity
    let motion: OrbitMeshyMotion
    private let indices: [Int]
    private var previousPose: OrbitPose?
    private var previousClip: OrbitMeshyClip?
    private var transitionFrom: [Transform]?
    private var transitionStarted: TimeInterval = 0

    static var isAvailable: Bool {
        if unavailable { return false }
        do { _ = try resources(); return true }
        catch {
            unavailable = true
            NSLog("Orbit: modello Meshy non disponibile: %@", String(describing: error))
            return false
        }
    }

    private static func resources() throws -> (Entity, OrbitMeshyMotion) {
        if let cached { return cached }
        guard let model = Bundle.module.url(forResource: "AeroMeshy", withExtension: "usdz", subdirectory: "OrbitModels"),
              let tracks = Bundle.module.url(forResource: "AeroMeshyMotion", withExtension: "json", subdirectory: "OrbitModels") else {
            throw OrbitMeshyMotion.AssetError.missingResource
        }
        let prototype = try Entity.load(contentsOf: model)
        let motion = try OrbitMeshyMotion(url: tracks)
        guard let skin = findSkin(in: prototype), skin.jointNames.count == motion.jointNames.count,
              skin.jointTransforms.count == motion.jointNames.count,
              Set(skin.jointNames) == Set(motion.jointNames) else { throw OrbitMeshyMotion.AssetError.incompatibleSkeleton }
        cached = (prototype, motion)
        return (prototype, motion)
    }

    private static func findSkin(in entity: Entity) -> ModelEntity? {
        if let model = entity as? ModelEntity, !model.jointNames.isEmpty { return model }
        for child in entity.children { if let found = findSkin(in: child) { return found } }
        return nil
    }

    init() throws {
        let (prototype, library) = try Self.resources()
        root = prototype.clone(recursive: true)
        motion = library
        guard let skin = Self.findSkin(in: root), skin.jointTransforms.count == motion.jointNames.count else {
            throw OrbitMeshyMotion.AssetError.missingSkeleton
        }
        self.skin = skin
        indices = try skin.jointNames.map { name in
            guard let index = library.jointNames.firstIndex(of: name) else { throw OrbitMeshyMotion.AssetError.incompatibleSkeleton }
            return index
        }
        apply(pose: .idle, elapsed: 0, moving: false)
    }

    func apply(pose: OrbitPose, elapsed: TimeInterval, moving: Bool,
               blendTransitions: Bool = false, now: TimeInterval = ProcessInfo.processInfo.systemUptime,
               clip: OrbitMeshyClip? = nil, useDefault: Bool = true) {
        let selected = useDefault ? pose.defaultMeshyClip : clip
        if previousPose != pose || previousClip != selected {
            transitionFrom = previousPose == nil ? nil : skin.jointTransforms
            transitionStarted = now
            previousPose = pose
            previousClip = selected
        }
        let sampled = motion.sample(pose: pose, elapsed: elapsed, moving: moving, clip: selected, useDefault: false)
        var transforms = indices.map { sampled[$0] }
        if moving, blendTransitions, let from = transitionFrom, now - transitionStarted < 0.18 {
            let t = Float(max(0, (now - transitionStarted) / 0.18))
            transforms = OrbitMeshyMotion.blend(from, transforms, t*t*(3-2*t))
        } else { transitionFrom = nil }
        skin.jointTransforms = transforms
    }

    func apply(clip: OrbitMeshyClip, elapsed: TimeInterval, moving: Bool) {
        // A clip preview is independent of Orbit states and never auto-loops.
        let sampled = motion.sample(clip: clip, elapsed: elapsed, moving: moving)
        skin.jointTransforms = indices.map { sampled[$0] }
    }
}

struct OrbitMascotArtwork: View {
    var pose: OrbitPose
    var elapsed: TimeInterval
    var moving: Bool
    var blendTransitions = false
    var clip: OrbitMeshyClip? = nil
    var useDefault = true

    var body: some View {
        if OrbitMeshyRig.isAvailable {
            OrbitMeshy3DView(pose: pose, elapsed: elapsed, moving: moving, blendTransitions: blendTransitions,
                             clip: clip, useDefault: useDefault)
                .allowsHitTesting(false)
        } else {
            OrbitSpriteView(pose: pose, elapsed: elapsed, moving: moving)
        }
    }
}

struct OrbitMeshy3DView: NSViewRepresentable {
    var pose: OrbitPose
    var elapsed: TimeInterval
    var moving: Bool
    var blendTransitions = false
    var clip: OrbitMeshyClip? = nil
    var useDefault = true
    var previewClip: OrbitMeshyClip? = nil

    @MainActor final class Coordinator {
        let rig = try? OrbitMeshyRig()
        let camera = PerspectiveCamera()
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> ARView {
        let view = ARView(frame: .zero)
        view.environment.background = .color(.clear)
        view.wantsLayer = true
        view.layer?.isOpaque = false
        let anchor = AnchorEntity(world: .zero)
        if let rig = context.coordinator.rig { anchor.addChild(rig.root) }
        let camera = context.coordinator.camera
        camera.look(at: [0, 0.97, 0], from: [-0.65, 1.05, 4.7], relativeTo: nil)
        anchor.addChild(camera)
        for (position, intensity): (SIMD3<Float>, Float) in [([-2, 3, 3], 1700), ([2, 1.5, 2], 750), ([1, 2, -2], 1400)] {
            let light = DirectionalLight()
            light.light.color = .white
            light.light.intensity = intensity
            light.look(at: [0, 1, 0], from: position, relativeTo: nil)
            anchor.addChild(light)
        }
        view.scene.addAnchor(anchor)
        updateRig(context.coordinator.rig)
        updateCamera(view, coordinator: context.coordinator)
        return view
    }
    func updateNSView(_ view: ARView, context: Context) {
        updateRig(context.coordinator.rig)
        updateCamera(view, coordinator: context.coordinator)
    }
    private func updateCamera(_ view: ARView, coordinator: Coordinator) {
        let selected = previewClip ?? (useDefault ? pose.defaultMeshyClip : clip) ?? .wave
        guard let framing = coordinator.rig?.motion.clips[selected.rawValue]?.framing else { return }
        let aspect = view.bounds.height > 0 ? view.bounds.width / view.bounds.height : 2 / 3
        coordinator.camera.camera.fieldOfViewInDegrees = framing.fieldOfView(aspect: aspect)
    }
    private func updateRig(_ rig: OrbitMeshyRig?) {
        if let previewClip { rig?.apply(clip: previewClip, elapsed: elapsed, moving: moving) }
        else { rig?.apply(pose: pose, elapsed: elapsed, moving: moving, blendTransitions: blendTransitions,
                         clip: clip, useDefault: useDefault) }
    }
    static func dismantleNSView(_ view: ARView, coordinator: Coordinator) { view.scene.anchors.removeAll() }
}
