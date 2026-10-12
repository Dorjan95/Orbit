import XCTest
import AppKit
import SwiftUI
@testable import Jarvis

final class WorkflowConnectionTests: XCTestCase {
    @MainActor func testRewireDropCancelClickToConnectAndPersistBothOutcomes() throws {
        let interaction = WorkflowConnectionInteraction()
        var graph = WorkflowDefinition.standard
        let review = try XCTUnwrap(graph.node("review"))
        interaction.begin(source: review, output: .failure)
        interaction.move(CGPoint(x: 900, y: 600))
        interaction.drop(CGPoint(x: 900, y: 600), in: &graph)
        XCTAssertEqual(graph.node("review")?.failure, "correction", "Empty drop must preserve the existing edge")
        interaction.begin(source: review, output: .failure)
        let command = WorkflowNode(id: "retry", kind: .command, title: "Retry", command: "true", success: "correction", maxVisits: 2, x: 790, y: 210)
        graph.nodes.append(command)
        interaction.move(command.inputPoint)
        XCTAssertEqual(graph.node("review")?.failure, "correction", "Preview must not commit an edge")
        interaction.drop(command.inputPoint, in: &graph)
        XCTAssertEqual(graph.node("review")?.failure, "retry")
        XCTAssertNil(graph.validationError)
        interaction.begin(source: try XCTUnwrap(graph.node("implementation")), output: .success)
        XCTAssertTrue(interaction.connect(to: "retry", in: &graph), "Click-to-connect must also work without a drag")
        XCTAssertEqual(graph.node("implementation")?.success, "retry")
        let decoded = try JSONDecoder().decode(WorkflowDefinition.self, from: JSONEncoder().encode(graph))
        XCTAssertEqual(decoded.node("review")?.failure, "retry")
        interaction.begin(source: command, output: .failure)
        interaction.move(CGPoint(x: 100, y: 100)); interaction.cancel()
        interaction.drop(review.inputPoint, in: &graph)
        XCTAssertNil(graph.node("retry")?.failure)
        interaction.disconnect(sourceID: "review", output: .failure, in: &graph)
        XCTAssertNil(graph.node("review")?.failure)
        XCTAssertEqual(graph.node("review")?.success, "verification")
    }
    @MainActor func testConnectionsKeepPlanGateAndBoundedSelfLoops() throws {
        var graph = WorkflowDefinition.standard
        let interaction = WorkflowConnectionInteraction()
        interaction.begin(source: try XCTUnwrap(graph.node("plan")), output: .success)
        XCTAssertFalse(interaction.connect(to: "implementation", in: &graph))
        XCTAssertEqual(graph.node("plan")?.success, "approval")
        XCTAssertTrue(interaction.message.contains("Approva piano"))
        interaction.begin(source: try XCTUnwrap(graph.node("implementation")), output: .failure)
        XCTAssertFalse(interaction.connect(to: "review", in: &graph))
        XCTAssertNil(graph.node("implementation")?.failure)
        interaction.begin(source: try XCTUnwrap(graph.node("review")), output: .failure)
        XCTAssertTrue(interaction.connect(to: "review", in: &graph))
        XCTAssertEqual(graph.node("review")?.failure, "review")
        XCTAssertEqual(graph.node("review")?.maxVisits, 4)
        XCTAssertNil(graph.validationError)
    }
    @MainActor func testRenderedPortDragRewiresWithoutMovingCardAndEscapeAborts() throws {
        var graph = WorkflowDefinition.standard
        var selected = "plan"
        let interaction = WorkflowConnectionInteraction()
        let host = NSHostingView(rootView: WorkflowCanvasView(definition: Binding(get: { graph }, set: { graph = $0 }), selected: Binding(get: { selected }, set: { selected = $0 }), connections: interaction))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 360), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host; defer { window.contentView = nil }
        layout(host)
        let port = try XCTUnwrap(ports(host).first { $0.sourceID == "review" && $0.output == .failure })
        let before = try XCTUnwrap(graph.node("review"))
        let start = port.convert(CGPoint(x: port.bounds.midX, y: port.bounds.midY), to: nil)
        XCTAssertTrue(host.hitTest(host.superview?.convert(start, from: nil) ?? start) === port, "Ports must own events ahead of card dragging: \(String(describing: host.hitTest(host.superview?.convert(start, from: nil) ?? start))), start \(start), viewport \(String(describing: port.enclosingScrollView?.documentVisibleRect))")
        // A click can arm the port before the user decides to drag that same output.
        port.mouseDown(with: try event(.leftMouseDown, point: start, window: window))
        port.mouseUp(with: try event(.leftMouseUp, point: start, window: window)); layout(host)
        XCTAssertEqual(interaction.sourceID, "review"); XCTAssertFalse(interaction.isDragging)
        port.mouseDown(with: try event(.leftMouseDown, point: start, window: window))
        let target = try XCTUnwrap(graph.node("verification"))
        let anchor = WorkflowOutput.failure.point(on: before)
        let scale = try XCTUnwrap(port.enclosingScrollView).magnification
        let end = CGPoint(x: start.x + (target.inputPoint.x - anchor.x) * scale, y: start.y - (target.inputPoint.y - anchor.y) * scale)
        port.mouseDragged(with: try event(.leftMouseDragged, point: end, window: window)); layout(host)
        XCTAssertEqual(interaction.sourceID, "review"); XCTAssertTrue(interaction.isDragging)
        XCTAssertEqual(graph.node("review")?.failure, "correction")
        port.mouseUp(with: try event(.leftMouseUp, point: end, window: window)); layout(host)
        XCTAssertEqual(graph.node("review")?.failure, "verification")
        XCTAssertEqual(graph.node("review")?.x, before.x); XCTAssertEqual(graph.node("review")?.y, before.y)
        // An invalid plan edge must not replace its approval gate.
        let planPort = try XCTUnwrap(ports(host).first { $0.sourceID == "plan" })
        let planStart = planPort.convert(CGPoint(x: planPort.bounds.midX, y: planPort.bounds.midY), to: nil)
        planPort.mouseDown(with: try event(.leftMouseDown, point: planStart, window: window))
        planPort.mouseDragged(with: try event(.leftMouseDragged, point: CGPoint(x: planStart.x + 100, y: planStart.y - 20), window: window))
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        planPort.keyDown(with: escape)
        planPort.mouseUp(with: try event(.leftMouseUp, point: planStart, window: window))
        XCTAssertNil(interaction.sourceID); XCTAssertEqual(graph.node("plan")?.success, "approval")
        let menu = try XCTUnwrap(port.menu(for: try event(.rightMouseDown, point: start, window: window)))
        XCTAssertEqual(menu.items.first?.title, "Scollega fallito")
        port.disconnect?()
        XCTAssertNil(graph.node("review")?.failure)
    }
    @MainActor func testPortTracksNonCentralGrabAndScrolledDocument() throws {
        final class Document: NSView { override var isFlipped: Bool { true } }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: window.contentLayoutRect)
        let document = Document(frame: CGRect(x: 0, y: 0, width: 1280, height: 760)); scroll.documentView = document
        window.contentView = scroll; defer { window.contentView = nil }
        let port = WorkflowConnectionDragView(frame: CGRect(x: 183, y: 30, width: 44, height: 28)); document.addSubview(port)
        var cursor: CGPoint?; var dropped: CGPoint?
        port.begin = { CGPoint(x: 205, y: 44) }; port.move = { cursor = $0 }; port.finish = { dropped = $0 }
        let start = port.convert(CGPoint(x: 12, y: 14), to: nil)
        port.mouseDown(with: try event(.leftMouseDown, point: start, window: window))
        scroll.contentView.scroll(to: CGPoint(x: 80, y: 100)); scroll.reflectScrolledClipView(scroll.contentView)
        port.mouseDragged(with: try event(.leftMouseDragged, point: start, window: window))
        XCTAssertEqual(cursor?.x, 275); XCTAssertEqual(cursor?.y, 144)
        port.mouseUp(with: try event(.leftMouseUp, point: start, window: window))
        XCTAssertEqual(dropped, cursor)
    }
    @MainActor func testConnectionPreviewScreens() throws {
        guard let path = ProcessInfo.processInfo.environment["ORBIT_CONNECTION_PREVIEW_DIR"] else { throw XCTSkip("Optional connection UI previews") }
        let root = URL(fileURLWithPath: path); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for linear in [false, true] {
        for reduced in [false, true] {
            var graph = WorkflowDefinition.standard; let interaction = WorkflowConnectionInteraction()
            if linear {
                let positions: [WorkflowNodeKind: CGPoint] = [.plan: .zero, .approval: CGPoint(x: 280, y: -140), .implementation: CGPoint(x: 540, y: 0), .review: CGPoint(x: 810, y: 0), .verification: CGPoint(x: 1080, y: 0), .correction: CGPoint(x: 0, y: 220)]
                for index in graph.nodes.indices {
                    let point = try XCTUnwrap(positions[graph.nodes[index].kind])
                    graph.nodes[index].x = point.x; graph.nodes[index].y = point.y
                }
            } else {
                interaction.begin(source: try XCTUnwrap(graph.node("review")), output: .failure)
                interaction.move(try XCTUnwrap(graph.node("verification")).inputPoint)
            }
            let content = WorkflowCanvasView(definition: .constant(graph), selected: .constant("review"), connections: interaction).transaction { $0.disablesAnimations = reduced }.preferredColorScheme(.dark)
            let host = NSHostingView(rootView: content)
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: linear ? 1280 : 1000, height: linear ? 600 : 360), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host; layout(host)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: root.appendingPathComponent((linear ? "linear" : "connecting") + (reduced ? "-reduced.png" : ".png")))
            window.contentView = nil
        }
        }
    }
    @MainActor private func layout(_ host: NSView) { host.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.03)); host.layoutSubtreeIfNeeded() }
    @MainActor private func ports(_ view: NSView) -> [WorkflowConnectionDragView] { (view as? WorkflowConnectionDragView).map { [$0] } ?? view.subviews.flatMap(ports) }
    @MainActor private func event(_ type: NSEvent.EventType, point: CGPoint, window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }
}
