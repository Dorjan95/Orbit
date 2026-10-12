import Foundation
import simd

/// Continuous joint targets for the 3D study. No sprite frames or pose dissolves.
enum OrbitThinkingMotion {
    static let duration: TimeInterval = 2.6
    static let upperArm: Float = 0.29
    static let forearm: Float = 0.27
    static let leftShoulder = SIMD3<Float>(-0.23, 1.27, 0)
    static let rightShoulder = SIMD3<Float>(0.23, 1.27, 0)

    struct Arm {
        let shoulder: SIMD3<Float>
        let elbow: SIMD3<Float>
        let wrist: SIMD3<Float>
    }
    struct Pose {
        let left: Arm
        let right: Arm
        let handTurn: Float
        let headTilt: Float
        let gaze: Float
    }

    static func sample(at elapsed: TimeInterval, moving: Bool = true) -> Pose {
        let t = moving ? max(0, elapsed) : duration
        let lift = ease(Float(t / 2.15))
        let support = ease(Float((t - 0.18) / 1.9))
        let settle = ease(Float((t - 1.7) / 0.9))
        let leftRest = SIMD3<Float>(-0.34, 0.73, 0.045)
        let rightRest = SIMD3<Float>(0.34, 0.73, 0.045)
        let leftTarget = SIMD3<Float>(-0.052, 1.31, 0.265)
        let rightTarget = SIMD3<Float>(-0.105, 1.065, 0.22)
        return Pose(
            left: solve(shoulder: leftShoulder, target: mix(leftRest, leftTarget, lift), pole: [-0.45, 0.90, 0.20]),
            right: solve(shoulder: rightShoulder, target: mix(rightRest, rightTarget, support), pole: [0.39, 0.90, 0.22]),
            handTurn: .pi * lift, headTilt: -0.10 * settle, gaze: 0.012 * settle)
    }

    // Minimum-jerk interpolation: zero velocity and acceleration at either end.
    private static func ease(_ value: Float) -> Float {
        let t = min(1, max(0, value))
        return t * t * t * (10 + t * (-15 + 6 * t))
    }
    private static func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> { a + (b - a) * t }

    /// Analytic two-bone IK preserves arm lengths throughout the hand's arc.
    private static func solve(shoulder: SIMD3<Float>, target: SIMD3<Float>, pole: SIMD3<Float>) -> Arm {
        let direction = simd_normalize(target - shoulder)
        let distance = min(upperArm + forearm - 0.0001, max(0.025, simd_distance(target, shoulder)))
        let along = (upperArm * upperArm - forearm * forearm + distance * distance) / (2 * distance)
        let height = sqrt(max(0, upperArm * upperArm - along * along))
        let poleDelta = pole - shoulder
        let perpendicular = simd_normalize(poleDelta - direction * simd_dot(poleDelta, direction))
        return Arm(shoulder: shoulder, elbow: shoulder + direction * along + perpendicular * height,
                   wrist: shoulder + direction * distance)
    }
}
