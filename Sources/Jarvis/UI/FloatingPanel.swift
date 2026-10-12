import AppKit
import SwiftUI

/// Non-activating, always-on-top, all-Spaces, transparent NSPanel hosting SwiftUI (§5.1, §5.2).
final class FloatingPanel<Content: View>: NSPanel {
    private let host: EdgeToEdgeHostingView<Content>

    init(content: Content, draggable: Bool) {
        host = EdgeToEdgeHostingView(rootView: content)
        super.init(contentRect: NSRect(x: 0, y: 0, width: 320, height: 56),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false   // the glass draws its own single shadow
        hidesOnDeactivate = false
        isMovableByWindowBackground = draggable
        isReleasedWhenClosed = false
        animationBehavior = .none
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        becomesKeyOnlyIfNeeded = true
        host.translatesAutoresizingMaskIntoConstraints = false
        contentView = host
        host.sizingOptions = [.intrinsicContentSize]
    }

    override var canBecomeKey: Bool { true }   // needed for the Reply text field; nonactivating keeps focus in the user's app otherwise
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    func update(_ content: Content) { host.rootView = content }

    /// Resize to the SwiftUI ideal size, keeping the top edge (pill) or top-left (overlay) anchored.
    func fitToContent(anchorTopCenter: Bool) {
        host.layoutSubtreeIfNeeded()
        var size = host.intrinsicContentSize
        if size.width <= 0 || size.height <= 0 { size = host.fittingSize }
        guard size.width > 0, size.height > 0 else { return }
        var f = frame
        let top = f.maxY
        if anchorTopCenter { f.origin.x = f.midX - size.width / 2 }
        f.size = size
        f.origin.y = top - size.height
        setFrame(f, display: true)
    }
}

private final class EdgeToEdgeHostingView<Content: View>: NSHostingView<Content> {
    override var safeAreaInsets: NSEdgeInsets { .init() }
    override var safeAreaRect: NSRect { bounds }
}
