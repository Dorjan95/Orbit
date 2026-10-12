import SwiftUI
import AppKit

/// A port owns its mouse sequence; the card's move surface never receives these events.
struct WorkflowConnectionDragSurface: NSViewRepresentable {
    let sourceID: String
    let output: WorkflowOutput
    var begin: () -> CGPoint
    var move: (CGPoint) -> Void
    var finish: (CGPoint) -> Void
    var cancel: () -> Void
    var disconnect: (() -> Void)?
    func makeNSView(context: Context) -> WorkflowConnectionDragView { WorkflowConnectionDragView() }
    func updateNSView(_ view: WorkflowConnectionDragView, context: Context) {
        view.sourceID = sourceID; view.output = output
        view.begin = begin; view.move = move; view.finish = finish; view.cancel = cancel; view.disconnect = disconnect
    }
    static func dismantleNSView(_ view: WorkflowConnectionDragView, coordinator: ()) { view.endDrag() }
}

final class WorkflowConnectionDragView: NSView {
    var sourceID = ""
    var output = WorkflowOutput.success
    var begin: (() -> CGPoint)?
    var move: ((CGPoint) -> Void)?
    var finish: ((CGPoint) -> Void)?
    var cancel: (() -> Void)?
    var disconnect: (() -> Void)?
    private weak var coordinateView: NSView?
    private var pointerOrigin: CGPoint?
    private var portOrigin: CGPoint?
    private var dragged = false
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func mouseDown(with event: NSEvent) {
        coordinateView = enclosingScrollView?.documentView ?? window?.contentView
        pointerOrigin = point(event)
        if let anchor = begin?() {
            let local = convert(event.locationInWindow, from: nil)
            portOrigin = CGPoint(x: anchor.x + local.x - bounds.midX,
                y: anchor.y + (isFlipped ? local.y - bounds.midY : bounds.midY - local.y))
        } else { portOrigin = nil }
        dragged = false
        window?.makeFirstResponder(self)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let position = location(event) else { return }
        dragged = true; move?(position)
    }
    override func mouseUp(with event: NSEvent) {
        if dragged, let position = location(event) { finish?(position) }
        endDrag()
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelOperation(nil) } else { super.keyDown(with: event) }
    }
    override func cancelOperation(_ sender: Any?) { endDrag(); cancel?() }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard disconnect != nil else { return nil }
        let menu = NSMenu()
        let item = menu.addItem(withTitle: "Scollega \(output.label.lowercased())", action: #selector(removeConnection), keyEquivalent: "")
        item.target = self; return menu
    }
    @objc private func removeConnection() { endDrag(); disconnect?() }
    func endDrag() { coordinateView = nil; pointerOrigin = nil; portOrigin = nil; dragged = false }
    private func point(_ event: NSEvent) -> CGPoint? {
        guard let coordinateView else { return nil }
        let p = coordinateView.convert(event.locationInWindow, from: nil)
        return CGPoint(x: p.x, y: coordinateView.isFlipped ? p.y : -p.y)
    }
    private func location(_ event: NSEvent) -> CGPoint? {
        guard let origin = portOrigin, let pointer = pointerOrigin, let p = point(event) else { return nil }
        return CGPoint(x: origin.x + p.x - pointer.x, y: origin.y + p.y - pointer.y)
    }
}

struct WorkflowInputPortSurface: NSViewRepresentable {
    var select: () -> Void
    func makeNSView(context: Context) -> WorkflowInputPortView { WorkflowInputPortView() }
    func updateNSView(_ view: WorkflowInputPortView, context: Context) { view.select = select }
}
final class WorkflowInputPortView: NSView {
    var select: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { select?() }
}
