import SwiftUI
import AppKit
import Observation

/// Navigation is transient; zoom and viewport never alter the saved workflow.
@MainActor @Observable
final class WorkflowCanvasCamera {
    static let worldSize = CGSize(width: 8192, height: 8192)
    static let origin = CGPoint(x: 4096, y: 4096)
    var zoom = 1.0
    var visibleRect = CGRect.zero
    var handTool = false
    @ObservationIgnored weak var scrollView: NSScrollView?

    static func graphBounds(_ nodes: [WorkflowNode]) -> CGRect {
        guard !nodes.isEmpty else { return CGRect(x: -150, y: -90, width: 300, height: 180) }
        return nodes.reduce(CGRect.null) { $0.union($1.canvasRect) }.insetBy(dx: -60, dy: -60)
    }
    func updateViewport() {
        guard let scrollView else { return }
        zoom = scrollView.magnification
        let rect = scrollView.documentVisibleRect
        visibleRect = rect.offsetBy(dx: -Self.origin.x, dy: -Self.origin.y)
    }
    func setZoom(_ value: Double, around point: CGPoint? = nil) {
        guard let scrollView else { return }
        let rect = scrollView.documentVisibleRect
        scrollView.setMagnification(min(2.5, max(0.25, value)), centeredAt: point ?? CGPoint(x: rect.midX, y: rect.midY))
        updateViewport()
    }
    func center(on point: CGPoint) {
        guard let scrollView else { return }
        let size = scrollView.documentVisibleRect.size
        scrollView.contentView.scroll(to: CGPoint(x: point.x + Self.origin.x - size.width / 2, y: point.y + Self.origin.y - size.height / 2))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        updateViewport()
    }
    func fit(_ nodes: [WorkflowNode]) {
        guard let scrollView else { return }
        let bounds = Self.graphBounds(nodes)
        let size = scrollView.contentView.frame.size
        guard size.width > 0, size.height > 0 else { return }
        setZoom(min(1, min(size.width / bounds.width, size.height / bounds.height)))
        center(on: CGPoint(x: bounds.midX, y: bounds.midY))
    }
}

struct WorkflowZoomCanvas<Content: View>: NSViewRepresentable {
    let camera: WorkflowCanvasCamera
    let nodes: [WorkflowNode]
    @ViewBuilder var content: () -> Content
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WorkflowZoomScrollView {
        let scroll = WorkflowZoomScrollView()
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.hasHorizontalScroller = false; scroll.hasVerticalScroller = false
        scroll.usesPredominantAxisScrolling = false
        scroll.wantsLayer = true
        scroll.horizontalScrollElasticity = .none; scroll.verticalScrollElasticity = .none
        scroll.allowsMagnification = true; scroll.minMagnification = 0.25; scroll.maxMagnification = 2.5
        let host = NSHostingView(rootView: content())
        host.frame = CGRect(origin: .zero, size: WorkflowCanvasCamera.worldSize)
        scroll.documentView = host
        context.coordinator.host = host
        camera.scrollView = scroll
        scroll.ready = { [weak scroll, camera] in
            guard let scroll, !scroll.initiallyFitted else { return }
            scroll.initiallyFitted = true; camera.fit(nodes)
        }
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak camera] _ in
            MainActor.assumeIsolated { camera?.updateViewport() }
        }
        return scroll
    }
    func updateNSView(_ scroll: WorkflowZoomScrollView, context: Context) {
        context.coordinator.host?.rootView = content()
        scroll.handTool = camera.handTool
        scroll.ready = { [weak scroll, camera] in
            guard let scroll, !scroll.initiallyFitted else { return }
            scroll.initiallyFitted = true; camera.fit(nodes)
        }
    }
    static func dismantleNSView(_ scroll: WorkflowZoomScrollView, coordinator: Coordinator) {
        if let observer = coordinator.observer { NotificationCenter.default.removeObserver(observer) }
        scroll.ready = nil
    }
    final class Coordinator {
        var host: NSHostingView<Content>?
        var observer: NSObjectProtocol?
    }
}

final class WorkflowZoomScrollView: NSScrollView {
    var ready: (() -> Void)?
    var initiallyFitted = false
    var handTool = false
    private var panStart: CGPoint?
    private var panOrigin: CGPoint?
    override func layout() {
        super.layout()
        if !initiallyFitted, window != nil, contentView.frame.width > 0, contentView.frame.height > 0 {
            DispatchQueue.main.async { [weak self] in self?.ready?() }
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if handTool, hit != nil { return self }
        // SwiftUI can miss the half-port outside a card after NSScrollView magnifies
        // its hosting view. Resolve the native handles in document coordinates.
        if hit != nil, let documentView {
            func handles(_ view: NSView) -> [NSView] {
                if view is WorkflowConnectionDragView || view is WorkflowNodeDragView || view is WorkflowInputPortView { return [view] }
                return view.subviews.flatMap(handles)
            }
            let candidates = handles(documentView).reversed()
            for view in candidates where !(view is WorkflowNodeDragView) {
                if view.bounds.contains(view.convert(point, from: superview)) { return view }
            }
            for view in candidates where view is WorkflowNodeDragView {
                if view.bounds.contains(view.convert(point, from: superview)) { return view }
            }
        }
        return hit
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { startPan(event) }
    override func mouseDragged(with event: NSEvent) { continuePan(event) }
    override func mouseUp(with event: NSEvent) { endPan() }
    override func otherMouseDown(with event: NSEvent) { startPan(event) }
    override func otherMouseDragged(with event: NSEvent) { continuePan(event) }
    override func otherMouseUp(with event: NSEvent) { endPan() }
    func startPan(_ event: NSEvent) {
        panStart = event.locationInWindow; panOrigin = contentView.bounds.origin; NSCursor.closedHand.set()
    }
    func continuePan(_ event: NSEvent) {
        guard let start = panStart, let origin = panOrigin else { return }
        let p = event.locationInWindow
        contentView.scroll(to: CGPoint(x: origin.x - (p.x - start.x) / magnification, y: origin.y + (p.y - start.y) / magnification))
        reflectScrolledClipView(contentView)
    }
    func endPan() { panStart = nil; panOrigin = nil; NSCursor.arrow.set() }
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command), let documentView {
            let anchor = documentView.convert(event.locationInWindow, from: nil)
            setMagnification(min(maxMagnification, max(minMagnification, magnification * exp(event.scrollingDeltaY * 0.012))), centeredAt: anchor)
        } else { super.scrollWheel(with: event) }
    }
}

struct WorkflowCanvasBackdrop: NSViewRepresentable {
    var cancel: () -> Void
    func makeNSView(context: Context) -> WorkflowCanvasBackdropView { WorkflowCanvasBackdropView() }
    func updateNSView(_ view: WorkflowCanvasBackdropView, context: Context) { view.cancel = cancel }
}
final class WorkflowCanvasBackdropView: NSView {
    var cancel: (() -> Void)?
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.07, alpha: 1).setFill(); dirtyRect.fill()
        let path = NSBezierPath()
        let spacing = 28.0
        for x in stride(from: floor(dirtyRect.minX / spacing) * spacing, through: dirtyRect.maxX, by: spacing) {
            for y in stride(from: floor(dirtyRect.minY / spacing) * spacing, through: dirtyRect.maxY, by: spacing) {
                path.appendOval(in: CGRect(x: x, y: y, width: 1.5, height: 1.5))
            }
        }
        NSColor(calibratedWhite: 0.25, alpha: 1).setFill(); path.fill()
    }
    override func mouseDown(with event: NSEvent) { cancel?(); (enclosingScrollView as? WorkflowZoomScrollView)?.startPan(event) }
    override func mouseDragged(with event: NSEvent) { (enclosingScrollView as? WorkflowZoomScrollView)?.continuePan(event) }
    override func mouseUp(with event: NSEvent) { (enclosingScrollView as? WorkflowZoomScrollView)?.endPan() }
}
