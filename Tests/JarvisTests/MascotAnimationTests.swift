import XCTest
import AppKit
@testable import Jarvis

final class MascotAnimationTests: XCTestCase {
    @MainActor
    func testVoiceStateOverridesGreetingAndCompletion() {
        let model = OrbitAnimationModel()
        let now = Date(timeIntervalSince1970: 100)
        model.react(.greeting, at: now)
        XCTAssertEqual(model.pose(pillVisible: false, pillState: .listening, runningCount: 0, pendingCount: 0, at: now), .greeting)
        model.react(.success, at: now)
        XCTAssertEqual(model.pose(pillVisible: true, pillState: .listening, runningCount: 1, pendingCount: 0, at: now), .listening)
        XCTAssertEqual(model.pose(pillVisible: true, pillState: .thinking, runningCount: 1, pendingCount: 0, at: now), .thinking)
        XCTAssertEqual(model.pose(pillVisible: true, pillState: .error, runningCount: 0, pendingCount: 0, at: now), .error)
        XCTAssertEqual(model.pose(pillVisible: true, pillState: .speaking, runningCount: 0, pendingCount: 0, at: now), .success)
        let later = now.addingTimeInterval(4)
        XCTAssertEqual(model.pose(pillVisible: false, pillState: .listening, runningCount: 2, pendingCount: 0, at: later), .working)
        XCTAssertEqual(model.pose(pillVisible: false, pillState: .listening, runningCount: 2, pendingCount: 1, at: later), .clarify)
        XCTAssertEqual(model.pose(pillVisible: false, pillState: .listening, runningCount: 0, pendingCount: 0, at: later), .idle)
        model.dragging = true
        XCTAssertEqual(model.pose(pillVisible: true, pillState: .listening, runningCount: 0, pendingCount: 0, at: later), .dragging)
    }

    func testAnimationFramesStayInsideGridAndReducedMotionIsStill() {
        for pose in OrbitPose.allCases {
            for time in [-1.0, 0, 0.25, 1, 5, 40, 3600] {
                XCTAssertTrue((0..<pose.frameCount).contains(pose.frameIndex(elapsed: time, moving: true)))
                XCTAssertEqual(pose.frameIndex(elapsed: time, moving: false), pose == .listening || pose == .thinking ? 15 : 0)
            }
        }
        XCTAssertEqual(OrbitPose.greeting.frameIndex(elapsed: 20, moving: true), 15)
        XCTAssertEqual(OrbitPose.listening.message(runningCount: 0), "Dimmi tutto,\nti sto ascoltando")
    }

    func testBlendedFramesAreContinuousAtLoopTurnsAndGreetingHoldsItsLastPose() {
        let pose = OrbitPose.working
        let end = Double(pose.frameCount - 1) / pose.fps
        let before = pose.sample(elapsed: end - 0.001, moving: true)
        let after = pose.sample(elapsed: end + 0.001, moving: true)
        XCTAssertEqual(before.current, 14)
        XCTAssertEqual(before.next, 15)
        XCTAssertEqual(after.current, 15)
        XCTAssertEqual(after.next, 14)
        XCTAssertGreaterThan(before.blend, 0.98)
        XCTAssertLessThan(after.blend, 0.02)
        let held = OrbitPose.greeting.sample(elapsed: 10.025, moving: true)
        XCTAssertEqual(held.current, 15)
        XCTAssertEqual(held.next, 15)
        XCTAssertEqual(pose.sample(elapsed: 5.04, moving: false), .init(current: 0, next: 0, blend: 0))
        for pose in OrbitPose.allCases {
            XCTAssertEqual(pose.frameCount, 16)
            for step in 0..<600 {
                let sample = pose.sample(elapsed: Double(step) / 30, moving: true)
                XCTAssertTrue((0..<16).contains(sample.current))
                XCTAssertTrue((0..<16).contains(sample.next))
                XCTAssertTrue((0..<1).contains(sample.blend))
            }
        }
    }

    @MainActor
    func testEveryBundledPoseRendersWithoutAnOpaqueRectangle() throws {
        for pose in OrbitPose.allCases {
            let frames = OrbitSprites.frames(for: pose)
            XCTAssertEqual(frames.count, pose.frameCount)
            for frame in frames {
                let bitmap = NSBitmapImageRep(cgImage: frame)
                XCTAssertLessThan(try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)?.alphaComponent), 0.03, pose.rawValue)
                XCTAssertLessThan(try XCTUnwrap(bitmap.colorAt(x: frame.width / 2, y: 0)?.alphaComponent), 0.03, pose.rawValue)
                // Check the entire top and bottom edges, not only the center: clipped
                // boots can sit away from the center and otherwise go unnoticed.
                for x in stride(from: 0, to: frame.width, by: 4) {
                    XCTAssertLessThan(bitmap.colorAt(x: x, y: 0)!.alphaComponent, 0.03, pose.rawValue)
                    XCTAssertLessThan(bitmap.colorAt(x: x, y: frame.height - 1)!.alphaComponent, 0.03, pose.rawValue)
                }
                var centralAlpha: CGFloat = 0
                for x: Double in [0.35, 0.5, 0.65] {
                    for y: Double in [0.25, 0.4, 0.55, 0.7] {
                        let px = Int(Double(frame.width) * x), py = Int(Double(frame.height) * y)
                        centralAlpha = max(centralAlpha, bitmap.colorAt(x: px, y: py)?.alphaComponent ?? 0)
                    }
                }
                XCTAssertGreaterThan(centralAlpha, 0.9, pose.rawValue)
                XCTAssertEqual(Double(frame.width) / Double(frame.height), 2.0 / 3, accuracy: 0.01)
            }
        }
    }

    @MainActor
    func testUnavailableMicrophoneCannotStartFakeListening() {
        let wake = WakeService()
        var listeningStarted = false
        wake.onWake = { _ in listeningStarted = true }
        XCTAssertFalse(wake.captureFromMascot())
        XCTAssertFalse(wake.capturing)
        XCTAssertFalse(listeningStarted)
        wake.finishFromMascot()
        XCTAssertFalse(wake.capturing)
    }

    @MainActor
    func testListeningDescendsOnceAndRestartsOnlyForANewCapture() {
        let model = OrbitAnimationModel()
        let start = Date(timeIntervalSince1970: 1000)
        model.syncListening(active: true, at: start)
        XCTAssertEqual(model.elapsed(for: .listening, at: start), 0)
        let midway = start.addingTimeInterval(0.5)
        XCTAssertEqual(OrbitPose.listening.frameIndex(elapsed: model.elapsed(for: .listening, at: midway), moving: true), 6)
        model.syncListening(active: true, at: midway)
        XCTAssertEqual(model.listeningStarted, start, "Transcript updates must not reset the gesture")
        for time in [2.01, 3.2, 10.025, 60.1] {
            let frame = OrbitPose.listening.sample(elapsed: time, moving: true)
            XCTAssertEqual(frame.current, 15)
            XCTAssertEqual(frame.next, 15)
        }
        XCTAssertEqual(OrbitPose.listening.sample(elapsed: 0, moving: false), .init(current: 15, next: 15, blend: 0))
        model.syncListening(active: false)
        let second = start.addingTimeInterval(60)
        model.syncListening(active: true, at: second)
        XCTAssertEqual(OrbitPose.listening.frameIndex(elapsed: model.elapsed(for: .listening, at: second), moving: true), 0)
        // The approved greeting retains its original playback and final hold.
        XCTAssertEqual(OrbitPose.greeting.frameIndex(elapsed: 0.5, moving: true), 6)
        XCTAssertEqual(OrbitPose.greeting.frameIndex(elapsed: 10, moving: true), 15)
    }

    @MainActor
    func testListeningStartsWithTheExactStandingSpriteAndEndsLower() {
        let frames = OrbitSprites.frames(for: .listening)
        XCTAssertTrue(frames[0] === OrbitSprites.frames(for: .idle)[0])
        func topOfCharacter(_ frame: CGImage) -> Int {
            let bitmap = NSBitmapImageRep(cgImage: frame)
            for y in 0..<frame.height {
                for x in stride(from: 0, to: frame.width, by: 4) {
                    if bitmap.colorAt(x: x, y: y)!.alphaComponent > 0.9 { return y }
                }
            }
            return frame.height
        }
        let first = frames[0], last = frames[15]
        let tops = frames.map { Double(topOfCharacter($0)) / Double($0.height) }
        for (before, after) in zip(tops, tops.dropFirst()) {
            XCTAssertGreaterThanOrEqual(after + 0.015, before, "The lowering motion must not bounce back up: \(tops)")
        }
        XCTAssertGreaterThan(Double(topOfCharacter(last)) / Double(last.height),
                             Double(topOfCharacter(first)) / Double(first.height) + 0.15)
    }

    @MainActor
    func testThinkingEntersOnceAndHoldsUntilTheNextReasoningTurn() {
        let model = OrbitAnimationModel()
        let start = Date(timeIntervalSince1970: 2000)
        model.syncThinking(active: true, at: start)
        XCTAssertEqual(model.elapsed(for: .thinking, at: start), 0)
        XCTAssertTrue(OrbitSprites.frames(for: .thinking)[0] === OrbitSprites.frames(for: .idle)[0])
        let midway = start.addingTimeInterval(0.6)
        let elapsed = model.elapsed(for: .thinking, at: midway)
        XCTAssertEqual(OrbitPose.thinking.frameIndex(elapsed: elapsed, moving: true), 6)
        model.syncThinking(active: true, at: midway)
        XCTAssertEqual(model.thinkingStarted, start, "Progress updates must not replay the entry")
        for time in [1.6, 3.2, 10.025, 60.1] {
            let frame = OrbitPose.thinking.sample(elapsed: time, moving: true)
            XCTAssertEqual(frame.current, 15)
            XCTAssertEqual(frame.next, 15)
        }
        XCTAssertEqual(OrbitPose.thinking.sample(elapsed: 0, moving: false), .init(current: 15, next: 15, blend: 0))
        model.syncThinking(active: false)
        let second = start.addingTimeInterval(60)
        model.syncThinking(active: true, at: second)
        XCTAssertEqual(model.elapsed(for: .thinking, at: second), 0)
        XCTAssertEqual(OrbitPose.thinking.frameIndex(elapsed: 0, moving: true), 0)
        model.syncListening(active: true, at: second)
        XCTAssertEqual(model.listeningStarted, second, "Reasoning must not change the listening clock")
    }
}
