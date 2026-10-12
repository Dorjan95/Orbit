import XCTest
import RealityKit
import simd
@testable import Jarvis

final class OrbitMeshyMotionTests: XCTestCase {
    private struct Source: Decodable {
        struct Clip: Decodable { let duration: Double; let frames: Int }
        struct Sample: Decodable { let time: Double; let joints: [String: [Float]] }
        let sourceSHA256: String
        let fps: Double
        let clips: [String: Clip]
        let sourceSamples: [String: [Sample]]
    }

    @MainActor
    func testEveryNativeClipMatchesOriginalBlenderRigSamplesAndTiming() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "MeshyNativeSource", withExtension: "json", subdirectory: "Fixtures"))
        let source = try JSONDecoder().decode(Source.self, from: Data(contentsOf: url))
        let motion = try OrbitMeshyRig().motion
        XCTAssertEqual(motion.sourceSHA256, source.sourceSHA256)
        XCTAssertEqual(motion.fps, source.fps)
        XCTAssertEqual(Set(motion.clips.keys), Set(source.clips.keys))
        XCTAssertEqual(motion.clips.count, 12)
        for clip in OrbitMeshyClip.allCases {
            let native = try XCTUnwrap(source.clips[clip.rawValue])
            XCTAssertEqual(clip.duration, native.duration, accuracy: 1e-7)
            XCTAssertEqual(motion.clips[clip.rawValue]!.duration, native.duration, accuracy: 1e-7)
            XCTAssertEqual(motion.clips[clip.rawValue]!.frames.count, native.frames)
            for sample in source.sourceSamples[clip.rawValue]! {
                let actual = motion.sample(clip: clip, elapsed: sample.time, moving: true)
                for (name, pose) in zip(motion.jointNames, actual) {
                    let v = try XCTUnwrap(sample.joints[name])
                    XCTAssertLessThan(simd_distance(pose.translation, SIMD3(v[0],v[1],v[2])), 0.0001, clip.rawValue)
                    XCTAssertLessThan(simd_distance(pose.scale, SIMD3(v[7],v[8],v[9])), 0.001, clip.rawValue)
                    let q = simd_normalize(SIMD4(v[3],v[4],v[5],v[6]))
                    XCTAssertGreaterThan(abs(simd_dot(pose.rotation.vector, q)), 0.9999, clip.rawValue)
                }
            }
        }
    }

    @MainActor
    func testRealSkinnedAssetLoadsAndViewportsHaveIndependentPoses() throws {
        let desktop = try OrbitMeshyRig()
        let preview = try OrbitMeshyRig()
        XCTAssertEqual(desktop.skin.jointNames.count, 28)
        XCTAssertEqual(desktop.root.visualBounds(relativeTo: desktop.root).extents.y, 1.9, accuracy: 0.02)
        let previewStart = preview.skin.jointTransforms
        desktop.apply(pose: .listening, elapsed: OrbitMeshyClip.sitTransition.duration, moving: true)
        assertPoseEqual(preview.skin.jointTransforms, previewStart)
        XCTAssertGreaterThan(rotationDistance(desktop.skin.jointTransforms, previewStart), 0.5)
    }

    @MainActor
    func testListeningAndReasoningPlayOnceAndHoldTheirSuppliedEndpoint() throws {
        let motion = try OrbitMeshyRig().motion
        for pose in [OrbitPose.listening, .thinking] {
            let clip = try XCTUnwrap(pose.defaultMeshyClip)
            let end = motion.sample(clip: clip, elapsed: clip.duration, moving: true)
            for t in [clip.duration, clip.duration+0.1, 60.0, 600.0] {
                assertPoseEqual(motion.sample(pose: pose, elapsed: t, moving: true), end)
            }
            assertPoseEqual(motion.sample(pose: pose, elapsed: 0, moving: false), end)
        }
        let end = motion.sample(clip: .running, elapsed: OrbitMeshyClip.running.duration, moving: true)
        assertPoseEqual(motion.sample(pose: .listening, elapsed: 60, moving: true, clip: .running, useDefault: false), end)
    }

    @MainActor
    func testOnlyNativeLocomotionLoopsDuringWorkAndPreviewRemainsSinglePass() throws {
        let motion = try OrbitMeshyRig().motion
        let clip = OrbitMeshyClip.walking
        assertPoseEqual(motion.sample(pose: .working, elapsed: clip.duration+0.2, moving: true),
                        motion.sample(clip: clip, elapsed: 0.2, moving: true))
        assertPoseEqual(motion.sample(clip: clip, elapsed: clip.duration+10, moving: true),
                        motion.sample(clip: clip, elapsed: clip.duration, moving: true))
        assertPoseEqual(motion.sample(pose: .working, elapsed: 30, moving: true, clip: .dancing, useDefault: false),
                        motion.sample(clip: .dancing, elapsed: OrbitMeshyClip.dancing.duration, moving: true))
    }

    @MainActor
    func testStateTransitionBlendsFromCurrentPoseAndReducedMotionSkipsIt() throws {
        let rig = try OrbitMeshyRig()
        let standing = rig.skin.jointTransforms
        let duration = OrbitMeshyClip.sitTransition.duration
        rig.apply(pose: .listening, elapsed: duration, moving: true, blendTransitions: true, now: 100)
        assertPoseEqual(rig.skin.jointTransforms, standing)
        rig.apply(pose: .listening, elapsed: duration, moving: true, blendTransitions: true, now: 100.2)
        assertPoseEqual(rig.skin.jointTransforms, rig.motion.sample(pose: .listening, elapsed: duration, moving: true))
        rig.apply(pose: .thinking, elapsed: 0, moving: false, blendTransitions: true, now: 100.21)
        assertPoseEqual(rig.skin.jointTransforms, rig.motion.sample(pose: .thinking, elapsed: 0, moving: false))
    }

    @MainActor
    func testNewCaptureRestartsButTranscriptUpdateDoesNotReplayNativeClip() throws {
        let model = OrbitAnimationModel()
        let rig = try OrbitMeshyRig()
        let start = Date(timeIntervalSince1970: 10)
        model.syncListening(active: true, at: start)
        model.syncListening(active: true, at: start.addingTimeInterval(10))
        rig.apply(pose: .listening, elapsed: model.elapsed(for: .listening, at: start.addingTimeInterval(10)), moving: true)
        let held = rig.skin.jointTransforms
        model.syncListening(active: false)
        model.syncListening(active: true, at: start.addingTimeInterval(15))
        rig.apply(pose: .listening, elapsed: model.elapsed(for: .listening, at: start.addingTimeInterval(15)), moving: true)
        XCTAssertGreaterThan(rotationDistance(held, rig.skin.jointTransforms), 0.5)
    }

    @MainActor
    func testAssignmentsRoundTripAndReactionsFinishCompleteNativeClip() throws {
        var settings = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
        XCTAssertEqual(settings.meshClip(for: .greeting), .bigWave)
        settings.mascotClipAssignments = ["greeting": OrbitMeshyClip.wave.rawValue, "thinking": "standing", "listening": "missing"]
        let decoded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.meshClip(for: .greeting), .wave)
        XCTAssertNil(decoded.meshClip(for: .thinking))
        XCTAssertEqual(decoded.meshClip(for: .listening), .sitTransition)
        let model = OrbitAnimationModel()
        let start = Date(timeIntervalSince1970: 1)
        model.react(.success, at: start, duration: settings.mascotReactionDuration(for: .success))
        XCTAssertEqual(model.pose(pillVisible: false, pillState: .speaking, runningCount: 0, pendingCount: 0, at: start.addingTimeInterval(7.9)), .success)
        XCTAssertEqual(model.pose(pillVisible: false, pillState: .speaking, runningCount: 0, pendingCount: 0, at: start.addingTimeInterval(8.1)), .idle)
    }

    @MainActor
    func testOtherAssignedStatesStartAtEntryAndUpdatesPreserveTheirClock() {
        let model = OrbitAnimationModel()
        let start = Date(timeIntervalSince1970: 100)
        model.syncPlayback(pose: .speaking, at: start)
        XCTAssertEqual(model.elapsed(for: .speaking, at: start), 0)
        model.syncPlayback(pose: .speaking, at: start.addingTimeInterval(1))
        XCTAssertEqual(model.elapsed(for: .speaking, at: start.addingTimeInterval(1)), 1)
        model.syncPlayback(pose: .clarify, at: start.addingTimeInterval(2))
        model.syncPlayback(pose: .speaking, at: start.addingTimeInterval(3))
        XCTAssertEqual(model.elapsed(for: .speaking, at: start.addingTimeInterval(3)), 0)
    }

    func testPreviousDownloadAssignmentsMigrateWithoutKeepingRemovedClips() throws {
        let legacy = Data(#"{"mascotClipAssignments":{"listening":"Step_to_Sit_Transition","working":"Boxing_Guard_Prep_Straight_Punch","success":"Wave_One_Hand","thinking":"standing"},"mascotSize":130,"mascotAnimations":false}"#.utf8)
        let settings = try JSONDecoder().decode(Settings.self, from: legacy)
        XCTAssertEqual(settings.mascotClipAssignments["listening"], "Stand_to_Sit_Transition_M")
        XCTAssertEqual(settings.meshClip(for: .listening), .sitTransition)
        XCTAssertEqual(settings.meshClip(for: .working), .walking)
        XCTAssertNil(settings.mascotClipAssignments["working"])
        XCTAssertEqual(settings.meshClip(for: .success), .wave)
        XCTAssertNil(settings.meshClip(for: .thinking))
        XCTAssertEqual(settings.mascotSize, 130)
        XCTAssertFalse(settings.mascotAnimations)
    }

    private func assertPoseEqual(_ a: [Transform], _ b: [Transform], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.count, b.count, file: file, line: line)
        for (x, y) in zip(a, b) {
            XCTAssertLessThan(simd_distance(x.translation, y.translation), 0.00001, file: file, line: line)
            XCTAssertGreaterThan(abs(simd_dot(x.rotation.vector, y.rotation.vector)), 0.99999, file: file, line: line)
            XCTAssertLessThan(simd_distance(x.scale, y.scale), 0.00001, file: file, line: line)
        }
    }
    private func rotationDistance(_ a: [Transform], _ b: [Transform]) -> Float {
        zip(a, b).map { 2*acos(min(1, abs(simd_dot($0.rotation.vector, $1.rotation.vector)))) }.max() ?? 0
    }
}
