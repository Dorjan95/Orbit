import XCTest
import AppKit
import SwiftUI
@testable import Jarvis

final class WorkflowCanvasNavigationTests: XCTestCase {
    @MainActor func testEmptyCanvasHasFiniteCenteredViewportAndCanFitFirstNode() throws {
        let camera = WorkflowCanvasCamera()
        let host = NSHostingView(rootView: WorkflowCanvasView(definition: .constant(.empty), selected: .constant(""), connections: WorkflowConnectionInteraction(), camera: camera))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1100, height: 560), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host; defer { window.contentView = nil }; layout(host)
        XCTAssertTrue(camera.visibleRect.minX.isFinite); XCTAssertTrue(camera.visibleRect.minY.isFinite)
        XCTAssertEqual(camera.visibleRect.midX, 0, accuracy: 1); XCTAssertEqual(camera.visibleRect.midY, 0, accuracy: 1)
        camera.fit(WorkflowDefinition.research.nodes)
        let bounds = WorkflowCanvasCamera.graphBounds(WorkflowDefinition.research.nodes)
        XCTAssertEqual(camera.visibleRect.midX, bounds.midX, accuracy: 1); XCTAssertEqual(camera.visibleRect.midY, bounds.midY, accuracy: 1)
    }
    @MainActor func testEditorInitiallyCentersSavedCustomPositions() throws {
        var graph = WorkflowDefinition.standard
        for index in graph.nodes.indices { graph.nodes[index].x += 1400; graph.nodes[index].y -= 500 }
        let host = NSHostingView(rootView: WorkflowEditorView(definition: .constant(graph)))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1280, height: 820), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host; defer { window.contentView = nil }; layout(host)
        let scroll = try XCTUnwrap(descendants(host, WorkflowZoomScrollView.self).first)
        let visible = scroll.documentVisibleRect.offsetBy(dx: -WorkflowCanvasCamera.origin.x, dy: -WorkflowCanvasCamera.origin.y)
        let bounds = WorkflowCanvasCamera.graphBounds(graph.nodes)
        XCTAssertEqual(visible.midX, bounds.midX, accuracy: 1)
        XCTAssertEqual(visible.midY, bounds.midY, accuracy: 1)
        XCTAssertEqual(graph.nodes[0].x, 1430)
    }
    @MainActor func testFitCentersGraphAndZoomPreservesAnchorWithoutChangingNodes() throws {
        let graph = WorkflowDefinition.standard
        let camera = WorkflowCanvasCamera()
        let host = NSHostingView(rootView: WorkflowCanvasView(definition: .constant(graph), selected: .constant("plan"), connections: WorkflowConnectionInteraction(), camera: camera))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1100, height: 560), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host; defer { window.contentView = nil }; layout(host)
        let scroll = try XCTUnwrap(camera.scrollView)
        let document = try XCTUnwrap(scroll.documentView)
        let graphBounds = WorkflowCanvasCamera.graphBounds(graph.nodes)
        XCTAssertEqual(camera.visibleRect.midX, graphBounds.midX, accuracy: 1)
        XCTAssertEqual(camera.visibleRect.midY, graphBounds.midY, accuracy: 1)
        XCTAssertTrue(camera.visibleRect.contains(graph.nodes[0].canvasRect))
        let anchor = CGPoint(x: WorkflowCanvasCamera.origin.x + 520, y: WorkflowCanvasCamera.origin.y + 100)
        let before = document.convert(anchor, to: nil)
        camera.setZoom(1.8, around: anchor); layout(host)
        let after = document.convert(anchor, to: nil)
        XCTAssertEqual(after.x, before.x, accuracy: 1); XCTAssertEqual(after.y, before.y, accuracy: 1)
        camera.setZoom(9); XCTAssertEqual(camera.zoom, 2.5)
        camera.setZoom(0.01); XCTAssertEqual(camera.zoom, 0.25)
        camera.center(on: CGPoint(x: -500, y: -200))
        XCTAssertEqual(camera.visibleRect.midX, -500, accuracy: 1); XCTAssertEqual(camera.visibleRect.midY, -200, accuracy: 1)
        camera.fit(graph.nodes)
        XCTAssertEqual(graph, .standard)
    }
    @MainActor func testConnectionAndCardDraggingAtDifferentZoomLevelsAndAfterPan() throws {
        var graph = WorkflowDefinition.standard; var selected = "review"
        let camera = WorkflowCanvasCamera(); let interaction = WorkflowConnectionInteraction()
        let host = NSHostingView(rootView: WorkflowCanvasView(definition: Binding(get: { graph }, set: { graph = $0 }), selected: Binding(get: { selected }, set: { selected = $0 }), connections: interaction, camera: camera))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1100, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host; defer { window.contentView = nil }; layout(host)
        for scale in [0.5, 1.8] {
            camera.setZoom(scale)
            let sourcePosition = try XCTUnwrap(graph.node("review")); let targetPosition = try XCTUnwrap(graph.node("verification"))
            camera.center(on: CGPoint(x: (sourcePosition.x + 205 + targetPosition.x) / 2, y: 220)); layout(host)
            let port = try XCTUnwrap(descendants(host, WorkflowConnectionDragView.self).first { $0.sourceID == "review" && $0.output == .failure })
            let before = try XCTUnwrap(graph.node("review"))
            let start = port.convert(CGPoint(x: port.bounds.midX, y: port.bounds.midY), to: nil)
            XCTAssertTrue(host.hitTest(host.superview?.convert(start, from: nil) ?? start) === port)
            let target = try XCTUnwrap(graph.node("verification")); let origin = WorkflowOutput.failure.point(on: before)
            let end = CGPoint(x: start.x + (target.inputPoint.x - origin.x) * scale, y: start.y - (target.inputPoint.y - origin.y) * scale)
            port.mouseDown(with: try event(.leftMouseDown, start, window)); port.mouseDragged(with: try event(.leftMouseDragged, end, window)); layout(host)
            XCTAssertEqual(interaction.pointer?.x ?? 0, target.inputPoint.x, accuracy: 1)
            port.mouseUp(with: try event(.leftMouseUp, end, window)); layout(host)
            XCTAssertEqual(graph.node("review")?.failure, "verification")
            XCTAssertEqual(graph.node("review")?.x, before.x); XCTAssertEqual(graph.node("review")?.y, before.y)
            let input = try XCTUnwrap(descendants(host, WorkflowInputPortView.self).first { view in
                let document = view.enclosingScrollView!.documentView!
                let center = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: document)
                return abs(center.x - (WorkflowCanvasCamera.origin.x + target.inputPoint.x)) < 2 && abs(center.y - (WorkflowCanvasCamera.origin.y + target.inputPoint.y)) < 2
            })
            let inputPoint = input.convert(CGPoint(x: input.bounds.midX, y: input.bounds.midY), to: nil)
            XCTAssertTrue(host.hitTest(host.superview?.convert(inputPoint, from: nil) ?? inputPoint) === input)
            interaction.begin(source: before, output: .failure)
            input.mouseDown(with: try event(.leftMouseDown, inputPoint, window))
            XCTAssertNil(interaction.sourceID, "Input clicks must finish the accessible connection path at every zoom")
            let body = try XCTUnwrap(descendants(host, WorkflowNodeDragView.self).first { view in
                let document = view.enclosingScrollView!.documentView!
                let center = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: document)
                return abs(center.x - (WorkflowCanvasCamera.origin.x + before.x + 102.5)) < 2 && abs(center.y - (WorkflowCanvasCamera.origin.y + before.y + 50)) < 2
            })
            let bodyStart = body.convert(CGPoint(x: 50, y: 30), to: nil)
            body.mouseDown(with: try event(.leftMouseDown, bodyStart, window))
            let bodyEnd = CGPoint(x: bodyStart.x + 60 * scale, y: bodyStart.y - 30 * scale)
            body.mouseDragged(with: try event(.leftMouseDragged, bodyEnd, window)); layout(host)
            body.mouseUp(with: try event(.leftMouseUp, bodyEnd, window)); layout(host)
            XCTAssertEqual(graph.node("review")!.x, before.x + 60, accuracy: 1)
            XCTAssertEqual(graph.node("review")!.y, before.y + 30, accuracy: 1)
        }
    }
    @MainActor func testBackgroundAndHandToolPanViewportWithoutMovingNodes() throws {
        let camera = WorkflowCanvasCamera(); let graph = WorkflowDefinition.standard
        let host = NSHostingView(rootView: WorkflowCanvasView(definition: .constant(graph), selected: .constant("plan"), connections: WorkflowConnectionInteraction(), camera: camera))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1100, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host; defer { window.contentView = nil }; layout(host)
        let scroll = try XCTUnwrap(camera.scrollView as? WorkflowZoomScrollView)
        camera.setZoom(0.5); layout(host)
        let background = try XCTUnwrap(descendants(host, WorkflowCanvasBackdropView.self).first)
        let origin = scroll.contentView.bounds.origin
        let controlPoint = host.convert(CGPoint(x: 30, y: host.bounds.height - 32), to: nil)
        let controlHit = host.hitTest(host.superview?.convert(controlPoint, from: nil) ?? controlPoint)
        XCTAssertNotNil(controlHit); XCTAssertFalse(controlHit === background, "Canvas must not swallow the navigation toolbar")
        let mapPoint = host.convert(CGPoint(x: host.bounds.width - 70, y: host.bounds.height - 50), to: nil)
        XCTAssertFalse(host.hitTest(host.superview?.convert(mapPoint, from: nil) ?? mapPoint) === background, "Mini-map gestures must stay above the canvas")
        let start = scroll.convert(CGPoint(x: 80, y: 250), to: nil)
        XCTAssertTrue(host.hitTest(host.superview?.convert(start, from: nil) ?? start) === background)
        background.mouseDown(with: try event(.leftMouseDown, start, window))
        background.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: start.x + 50, y: start.y - 20), window))
        background.mouseUp(with: try event(.leftMouseUp, start, window)); layout(host)
        XCTAssertEqual(scroll.contentView.bounds.origin.x, origin.x - 100, accuracy: 1)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, origin.y - 40, accuracy: 1)
        camera.handTool = true; layout(host)
        let card = try XCTUnwrap(descendants(host, WorkflowNodeDragView.self).first)
        let cardPoint = card.convert(CGPoint(x: 50, y: 30), to: nil)
        XCTAssertTrue(host.hitTest(host.superview?.convert(cardPoint, from: nil) ?? cardPoint) === scroll)
        XCTAssertEqual(graph, .standard)
    }
    @MainActor private func layout(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        let deadline = Date().addingTimeInterval(1)
        repeat {
            RunLoop.current.run(until: Date().addingTimeInterval(0.06)); host.layoutSubtreeIfNeeded()
        } while descendants(host, WorkflowZoomScrollView.self).contains(where: { !$0.initiallyFitted }) && Date() < deadline
    }
    @MainActor private func descendants<T: NSView>(_ view: NSView, _ type: T.Type) -> [T] { (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, type) } }
    @MainActor private func event(_ type: NSEvent.EventType, _ point: CGPoint, _ window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }
}
