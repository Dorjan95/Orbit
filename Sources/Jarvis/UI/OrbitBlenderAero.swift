import AppKit
import RealityKit
import simd

@MainActor protocol OrbitAeroMotionRig: AnyObject {
    var root: Entity { get }
    func apply(elapsed: TimeInterval, moving: Bool)
}

/// The Blender-authored mesh is loaded once. Orbit drives its persistent joints
/// with the same approved targets as the original motion study.
@MainActor final class OrbitBlenderAeroRig: OrbitAeroMotionRig {
    let root: Entity
    let head: Entity
    let leftShoulder: Entity, leftElbow: Entity, leftHand: Entity
    let rightShoulder: Entity, rightElbow: Entity, rightHand: Entity
    private let leftEye: Entity, rightEye: Entity
    private let leftEyeRest: SIMD3<Float>, rightEyeRest: SIMD3<Float>

    enum AssetError: Error { case missingFile, missingJoint(String), invalidScale }

    init() throws {
        guard let url = Bundle.module.url(forResource: "Aero", withExtension: "usdz", subdirectory: "OrbitModels") else {
            throw AssetError.missingFile
        }
        let loaded = try Entity.load(contentsOf: url)
        root = loaded
        func joint(_ name: String) throws -> Entity {
            guard let entity = loaded.findEntity(named: name) else { throw AssetError.missingJoint(name) }
            return entity
        }
        head = try joint("AeroHead")
        leftShoulder = try joint("AeroShoulderLeft")
        leftElbow = try joint("AeroElbowLeft")
        leftHand = try joint("AeroHandLeft")
        rightShoulder = try joint("AeroShoulderRight")
        rightElbow = try joint("AeroElbowRight")
        rightHand = try joint("AeroHandRight")
        leftEye = try joint("AeroEyeLeft")
        rightEye = try joint("AeroEyeRight")
        leftEyeRest = leftEye.position; rightEyeRest = rightEye.position
        guard simd_distance(leftShoulder.position(relativeTo: root), OrbitThinkingMotion.leftShoulder) < 0.001,
              simd_distance(rightShoulder.position(relativeTo: root), OrbitThinkingMotion.rightShoulder) < 0.001 else {
            throw AssetError.invalidScale
        }
        apply(elapsed: 0, moving: true)
    }

    func apply(elapsed: TimeInterval, moving: Bool) {
        let pose = OrbitThinkingMotion.sample(at: elapsed, moving: moving)
        applyArm(pose.left, shoulder: leftShoulder, elbow: leftElbow, hand: leftHand,
                 handRotation: simd_quatf(angle: pose.handTurn, axis: [0, 0, 1]))
        applyArm(pose.right, shoulder: rightShoulder, elbow: rightElbow, hand: rightHand,
                 handRotation: simd_quatf(angle: -pose.handTurn * 0.46, axis: [0, 0, 1]))
        head.orientation = simd_quatf(angle: pose.headTilt, axis: [0, 0, 1]) *
            simd_quatf(angle: -pose.headTilt * 0.7, axis: [0, 1, 0])
        leftEye.position = leftEyeRest + [0, pose.gaze, 0]
        rightEye.position = rightEyeRest + [0, pose.gaze, 0]
    }

    private func applyArm(_ pose: OrbitThinkingMotion.Arm, shoulder: Entity, elbow: Entity,
                          hand: Entity, handRotation: simd_quatf) {
        shoulder.position = pose.shoulder
        let upper = simd_quatf(from: [0, -1, 0], to: simd_normalize(pose.elbow - pose.shoulder))
        let lower = simd_quatf(from: [0, -1, 0], to: simd_normalize(pose.wrist - pose.elbow))
        shoulder.orientation = upper
        elbow.position = [0, -OrbitThinkingMotion.upperArm, 0]
        elbow.orientation = upper.inverse * lower
        hand.position = [0, -OrbitThinkingMotion.forearm, 0]
        hand.orientation = lower.inverse * handRotation
    }
}
