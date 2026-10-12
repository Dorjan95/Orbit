import XCTest
import AppKit
import SwiftUI
@testable import Jarvis

final class WorkflowNodeDragTests: XCTestCase {
    @MainActor private final class CanvasView: NSView { override var isFlipped: Bool { true } }

    @MainActor private func event(_ type: NSEvent.EventType, point: CGPoint, window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }

    @MainActor func testDragFollowsPointerWhenCardFrameChangesAndCanvasScrolls() throws {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        defer { window.contentView = nil }
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        let canvas = CanvasView(frame: CGRect(x: 0, y: 0, width: 1280, height: 760))
        scroll.documentView = canvas; window.contentView = scroll
        var position = CGPoint(x: 30, y: 30)
        var selections = 0
        let handle = WorkflowNodeDragView(frame: CGRect(origin: position, size: CGSize(width: 205, height: 100)))
        canvas.addSubview(handle)
        handle.begin = { selections += 1; return position }
        handle.move = { point in position = point; handle.setFrameOrigin(point) }
        let start = canvas.convert(CGPoint(x: 85, y: 65), to: nil)
        handle.mouseDown(with: try event(.leftMouseDown, point: start, window: window))
        for delta in [CGPoint(x: 10, y: 5), CGPoint(x: 70, y: 40), CGPoint(x: 120, y: 70), CGPoint(x: 45, y: 25)] {
            // The view itself moves each time, but the physical pointer displacement
            // must produce exactly the corresponding document displacement.
            let target = canvas.convert(CGPoint(x: 85 + delta.x, y: 65 + delta.y), to: nil)
            handle.mouseDragged(with: try event(.leftMouseDragged, point: target, window: window))
            XCTAssertEqual(position.x, 30 + delta.x, accuracy: 0.01)
            XCTAssertEqual(position.y, 30 + delta.y, accuracy: 0.01)
        }
        let heldPointer = canvas.convert(CGPoint(x: 130, y: 90), to: nil)
        scroll.contentView.scroll(to: CGPoint(x: 80, y: 100)); scroll.reflectScrolledClipView(scroll.contentView)
        handle.mouseDragged(with: try event(.leftMouseDragged, point: heldPointer, window: window))
        XCTAssertEqual(position.x, 155, accuracy: 0.01)
        XCTAssertEqual(position.y, 155, accuracy: 0.01)
        handle.mouseUp(with: try event(.leftMouseUp, point: heldPointer, window: window))
        XCTAssertEqual(selections, 1)
        let saved = position
        handle.mouseDragged(with: try event(.leftMouseDragged, point: .zero, window: window))
        XCTAssertEqual(position, saved, "Released drag must not keep moving a node")
        // A second gesture must start from the newly saved position, including scroll.
        let secondStart = canvas.convert(CGPoint(x: saved.x + 50, y: saved.y + 30), to: nil)
        handle.mouseDown(with: try event(.leftMouseDown, point: secondStart, window: window))
        handle.mouseDragged(with: try event(.leftMouseDragged, point: CGPoint(x: secondStart.x + 20, y: secondStart.y - 15), window: window))
        XCTAssertEqual(position.x, saved.x + 20, accuracy: 0.01)
        XCTAssertEqual(position.y, saved.y + 15, accuracy: 0.01)
    }

    @MainActor func testRenderedSwiftUICardReceivesPointerAndKeepsItsPositionAcrossUpdates() throws {
        let host = NSHostingView(rootView: WorkflowEditorView(definition: .constant(.standard)))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1078, height: 755), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.1)); host.layoutSubtreeIfNeeded()
        func handles(_ view: NSView) -> [WorkflowNodeDragView] {
            (view as? WorkflowNodeDragView).map { [$0] } ?? view.subviews.flatMap(handles)
        }
        let handle = try XCTUnwrap(handles(host).first)
        XCTAssertNotNil(handle.enclosingScrollView, "Card must measure movement inside the actual SwiftUI scroll document")
        let before = handle.convert(CGPoint.zero, to: nil)
        let start = handle.convert(CGPoint(x: 40, y: 40), to: nil)
        let hit = host.hitTest(host.superview?.convert(start, from: nil) ?? start)
        XCTAssertTrue(hit === handle, "Drag hit: \(String(describing: hit)), handle: \(handle.frame), host point: \(host.convert(start, from: nil))")
        handle.mouseDown(with: try event(.leftMouseDown, point: start, window: window))
        for amount in [20.0, 40.0, 60.0] {
            handle.mouseDragged(with: try event(.leftMouseDragged, point: CGPoint(x: start.x + amount, y: start.y - amount / 2), window: window))
            RunLoop.current.run(until: Date().addingTimeInterval(0.02)); host.layoutSubtreeIfNeeded()
        }
        handle.mouseUp(with: try event(.leftMouseUp, point: CGPoint(x: start.x + 60, y: start.y - 30), window: window))
        RunLoop.current.run(until: Date().addingTimeInterval(0.02)); host.layoutSubtreeIfNeeded()
        let after = handle.convert(CGPoint.zero, to: nil)
        XCTAssertEqual(after.x - before.x, 60, accuracy: 1)
        XCTAssertEqual(after.y - before.y, -30, accuracy: 1)
    }

    @MainActor func testClickSelectsWithoutMovingAndDismantledDragCannotContinue() throws {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        defer { window.contentView = nil }
        let canvas = CanvasView(frame: window.contentLayoutRect); window.contentView = canvas
        let handle = WorkflowNodeDragView(frame: CGRect(x: 30, y: 30, width: 205, height: 100)); canvas.addSubview(handle)
        var selections = 0; var moves = 0
        handle.begin = { selections += 1; return CGPoint(x: 30, y: 30) }
        handle.move = { _ in moves += 1 }
        let point = canvas.convert(CGPoint(x: 70, y: 70), to: nil)
        handle.mouseDown(with: try event(.leftMouseDown, point: point, window: window))
        handle.mouseUp(with: try event(.leftMouseUp, point: point, window: window))
        XCTAssertEqual(selections, 1); XCTAssertEqual(moves, 0)
        handle.mouseDown(with: try event(.leftMouseDown, point: point, window: window))
        handle.endDrag()
        handle.mouseDragged(with: try event(.leftMouseDragged, point: CGPoint(x: point.x + 50, y: point.y), window: window))
        XCTAssertEqual(moves, 0)
        XCTAssertTrue(handle.acceptsFirstMouse(for: nil))
    }
}
