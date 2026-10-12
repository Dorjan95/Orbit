import XCTest
import AppKit
@testable import Jarvis

final class DesktopTests: XCTestCase {
    func testOldNotchSettingsMigrateToFloatingLayoutWithoutLosingModels() throws {
        let old = Data(#"{"notchEnabled":true,"codexModel":"my-model","overlayOrigin":[800,400]}"#.utf8)
        let settings = try JSONDecoder().decode(Settings.self, from: old)
        XCTAssertTrue(settings.mascotEnabled)
        XCTAssertFalse(settings.showIdlePill)
        XCTAssertEqual(settings.codexModel, "my-model")
        XCTAssertEqual(settings.overlayOrigin, CGPoint(x: 800, y: 400))
        var customized = settings
        customized.mascotOrigin = CGPoint(x: -700, y: 120)
        customized.mascotSize = 280
        customized.mascotEnabled = false
        customized.mascotAnimations = false
        let restored = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(customized))
        XCTAssertEqual(restored.mascotOrigin, customized.mascotOrigin)
        XCTAssertEqual(restored.mascotSize, 280)
        XCTAssertFalse(restored.mascotEnabled)
        XCTAssertFalse(restored.mascotAnimations)
        let huge = try JSONDecoder().decode(Settings.self, from: Data(#"{"mascotSize":999999}"#.utf8))
        XCTAssertEqual(huge.mascotSize, 320)
    }

    func testSecondaryDisplayPositionAndDisconnectedDisplayRecovery() {
        let main = CGRect(x: 0, y: 30, width: 1440, height: 840)
        let secondary = CGRect(x: -1920, y: -180, width: 1920, height: 1080)
        let size = CGSize(width: 150, height: 230)
        let origin = CGPoint(x: -1000, y: -100)
        let frame = DesktopLayout.fittedFrame(origin: origin, size: size, screens: [main, secondary], fallback: main)
        XCTAssertEqual(frame.origin, origin)
        let recovered = DesktopLayout.fittedFrame(origin: origin, size: size, screens: [main], fallback: main)
        XCTAssertTrue(main.contains(recovered))
        XCTAssertEqual(recovered.maxX, main.maxX - 24)
        let resized = DesktopLayout.fittedFrame(origin: CGPoint(x: 1400, y: 800), size: size, screens: [main], fallback: main)
        XCTAssertTrue(main.contains(resized))
        let pill = DesktopLayout.pillFrame(visible: main, size: CGSize(width: 380, height: 80))
        XCTAssertEqual(pill.maxY, main.maxY - 12)
        XCTAssertEqual(pill.midX, main.midX)
    }

    @MainActor
    func testBundledArtworkHasTransparentBackgroundAndVisibleCharacter() throws {
        let image = OrbitArtwork.image
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        XCTAssertEqual(bitmap.colorAt(x: 0, y: 0)?.alphaComponent, 0)
        XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.alphaComponent), 0.95)
        XCTAssertGreaterThan(bitmap.pixelsHigh, bitmap.pixelsWide)
    }

    @MainActor
    func testSessionSectionsKeepPendingWorkWhenClearingFinished() {
        let store = SessionStore()
        for s in store.sessions { store.dismiss(s.id) }
        func session(_ id: String, _ status: SessionStatus) -> Session {
            Session(id: id, projectName: "Demo", projectPath: "/tmp", agent: .codex, task: "Test", status: status)
        }
        store.insert(session("orbit-running", .running))
        store.insert(session("orbit-pending", .needsInput))
        store.insert(session("orbit-done", .done))
        store.insert(session("orbit-failed", .failed))
        store.insert(session("orbit-cancelled", .cancelled))
        XCTAssertEqual(Set(store.activeVisible.map(\.id)), ["orbit-running", "orbit-pending"])
        XCTAssertEqual(Set(store.finishedVisible.map(\.id)), ["orbit-done", "orbit-failed", "orbit-cancelled"])
        store.clearFinished()
        XCTAssertEqual(Set(store.visible.map(\.id)), ["orbit-running", "orbit-pending"])
        store.update("orbit-running") { $0.status = .done }
        XCTAssertEqual(store.activeVisible.map(\.id), ["orbit-pending"])
        XCTAssertEqual(store.finishedVisible.map(\.id), ["orbit-running"])
        for s in store.sessions { store.dismiss(s.id) }
    }
}
