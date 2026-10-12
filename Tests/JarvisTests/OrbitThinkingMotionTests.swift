import XCTest
import simd
import RealityKit
@testable import Jarvis

final class OrbitThinkingMotionTests: XCTestCase {
    @MainActor
    func testBlenderAssetLoadsAtCorrectScaleAndPreservesApprovedJoints() throws {
        let rig = try OrbitBlenderAeroRig()
        let bounds = rig.root.visualBounds(relativeTo: rig.root)
        XCTAssertGreaterThan(bounds.extents.y, 1.8)
        XCTAssertLessThan(bounds.extents.y, 2.1)
        XCTAssertGreaterThan(bounds.extents.x, 0.6)
        XCTAssertLessThan(bounds.extents.x, 1)
        for time in [0.0, 0.35, 1.2, 2.15, 2.6, 10] {
            rig.apply(elapsed: time, moving: true)
            let expected = OrbitThinkingMotion.sample(at: time)
            for (actual, target) in [(rig.leftHand, expected.left.wrist), (rig.rightHand, expected.right.wrist),
                                      (rig.leftElbow, expected.left.elbow), (rig.rightElbow, expected.right.elbow)] {
                XCTAssertLessThan(simd_distance(actual.position(relativeTo: rig.root), target), 0.0001)
            }
        }
        rig.apply(elapsed: 0, moving: false)
        XCTAssertLessThan(simd_distance(rig.leftHand.position(relativeTo: rig.root),
                                      OrbitThinkingMotion.sample(at: 2.6).left.wrist), 0.0001)
    }

    @MainActor
    func testRefinedAppearancePreservesAnimatedJointPositions() {
        let rig = OrbitAeroRig()
        for time in [0.0, 0.35, 1.2, 2.15, 2.6, 10] {
            rig.apply(elapsed: time, moving: true)
            let expected = OrbitThinkingMotion.sample(at: time)
            for (actual, target) in [(rig.leftHand, expected.left.wrist), (rig.rightHand, expected.right.wrist),
                                      (rig.leftElbow, expected.left.elbow), (rig.rightElbow, expected.right.elbow)] {
                XCTAssertLessThan(simd_distance(actual.position(relativeTo: rig.root), target), 0.0001)
            }
        }
    }

    func testContinuousMotionPreservesArmLengths() {
        var previous = OrbitThinkingMotion.sample(at: 0)
        for frame in 1...180 {
            let pose = OrbitThinkingMotion.sample(at: Double(frame) / 60)
            for arm in [pose.left, pose.right] {
                XCTAssertEqual(simd_distance(arm.shoulder, arm.elbow), OrbitThinkingMotion.upperArm, accuracy: 0.0001)
                XCTAssertEqual(simd_distance(arm.elbow, arm.wrist), OrbitThinkingMotion.forearm, accuracy: 0.0001)
                XCTAssertTrue(arm.wrist.x.isFinite && arm.wrist.y.isFinite && arm.wrist.z.isFinite)
            }
            XCTAssertLessThan(simd_distance(pose.left.wrist, previous.left.wrist), 0.015)
            XCTAssertLessThan(simd_distance(pose.left.elbow, previous.left.elbow), 0.02)
            previous = pose
        }
    }

    func testGestureSettlesAndReducedMotionUsesFinalPose() {
        let start = OrbitThinkingMotion.sample(at: 0)
        let end = OrbitThinkingMotion.sample(at: OrbitThinkingMotion.duration)
        XCTAssertGreaterThan(end.left.wrist.y, start.left.wrist.y + 0.5)
        XCTAssertLessThan(abs(end.left.wrist.x), 0.07)
        XCTAssertGreaterThan(end.left.wrist.z, 0.2)
        for time in [4.0, 20, 60] {
            let held = OrbitThinkingMotion.sample(at: time)
            XCTAssertEqual(held.left.wrist, end.left.wrist)
            XCTAssertEqual(held.right.elbow, end.right.elbow)
            XCTAssertEqual(held.headTilt, end.headTilt)
        }
        let still = OrbitThinkingMotion.sample(at: 0, moving: false)
        XCTAssertEqual(still.left.wrist, end.left.wrist)
        XCTAssertEqual(still.headTilt, end.headTilt)
    }
}
