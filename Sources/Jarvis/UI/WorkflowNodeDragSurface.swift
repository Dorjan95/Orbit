import SwiftUI
import AppKit

/// Own the pointer sequence separately from the SwiftUI button and scroll view.
/// Positions are measured in the scroll document, which does not move with the card.
struct WorkflowNodeDragSurface: NSViewRepresentable {
    var begin: () -> CGPoint
    var move: (CGPoint) -> Void

    func makeNSView(context: Context) -> WorkflowNodeDragView {
        let view = WorkflowNodeDragView()
        view.begin = begin; view.move = move
        return view
    }
    func updateNSView(_ view: WorkflowNodeDragView, context: Context) {
        view.begin = begin; view.move = move
    }
    static func dismantleNSView(_ view: WorkflowNodeDragView, coordinator: ()) { view.endDrag() }
}

final class WorkflowNodeDragView: NSView {
    var begin: (() -> CGPoint)?
    var move: ((CGPoint) -> Void)?
    private weak var coordinateView: NSView?
    private var pointerOrigin: CGPoint?
    private var nodeOrigin: CGPoint?
    private var hasDragged = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDown(with event: NSEvent) {
        // Capture before selection can relayout the inspector. The document remains
        // stable when this representable's frame is updated by SwiftUI on each move.
        hasDragged = false
        coordinateView = enclosingScrollView?.documentView ?? window?.contentView
        pointerOrigin = documentPoint(event)
        nodeOrigin = begin?()
    }
    override func mouseDragged(with event: NSEvent) {
        guard let origin = nodeOrigin, let pointer = pointerOrigin, let point = documentPoint(event) else { return }
        hasDragged = true
        NSCursor.closedHand.set()
        move?(CGPoint(x: origin.x + point.x - pointer.x, y: origin.y + point.y - pointer.y))
    }
    override func mouseUp(with event: NSEvent) {
        // AppKit may deliver a final location without a preceding mouseDragged.
        if hasDragged, let origin = nodeOrigin, let pointer = pointerOrigin, let point = documentPoint(event) {
            move?(CGPoint(x: origin.x + point.x - pointer.x, y: origin.y + point.y - pointer.y))
        }
        endDrag()
        window?.invalidateCursorRects(for: self)
    }
    func endDrag() { pointerOrigin = nil; nodeOrigin = nil; coordinateView = nil; hasDragged = false }

    private func documentPoint(_ event: NSEvent) -> CGPoint? {
        guard let coordinateView else { return nil }
        let point = coordinateView.convert(event.locationInWindow, from: nil)
        return CGPoint(x: point.x, y: coordinateView.isFlipped ? point.y : -point.y)
    }
}
