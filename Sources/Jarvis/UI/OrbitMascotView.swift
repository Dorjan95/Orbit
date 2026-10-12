import AppKit
import SwiftUI
import ImageIO

@MainActor enum OrbitArtwork {
    static let image: NSImage = {
        guard let url = Bundle.module.url(forResource: "orbit-aero", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { preconditionFailure("Missing Orbit Aero artwork") }
        return image
    }()
}

@MainActor enum OrbitSprites {
    private static var cache: [String: [CGImage]] = [:]
    static func frames(for pose: OrbitPose) -> [CGImage] {
        if let frames = cache[pose.atlas] { return frames }
        guard let url = Bundle.module.url(forResource: pose.atlas, withExtension: "png", subdirectory: "OrbitAnimations"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            preconditionFailure("Missing Orbit animation: \(pose.atlas)")
        }
        let width = image.width / pose.columns, height = width * 3 / 2
        // Generated atlases can have slightly uneven row spacing. Detect the transparent
        // gaps once, rather than clipping boots or leaking the preceding row into a pose.
        let bands = rowBands(in: image, rows: pose.rows)
        let scale = min(1, CGFloat(height - 16) / CGFloat(bands.map(\.count).max()!))
        var frames = (0..<pose.frameCount).map { index in
            let band = bands[index / pose.columns]
            let tile = image.cropping(to: CGRect(x: (index % pose.columns) * width, y: band.lowerBound,
                                                 width: width, height: band.count))!
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.interpolationQuality = .high
            // Same scale and floor baseline for all frames; preserve the jump within a row.
            context.draw(tile, in: CGRect(x: (CGFloat(width) - CGFloat(width) * scale) / 2, y: 8,
                width: CGFloat(width) * scale, height: CGFloat(band.count) * scale))
            return context.makeImage()!
        }
        if pose == .listening {
            // Generated rows can include a small upward bob at a row boundary.
            // Keep the descent in height order while retaining every intermediate pose.
            var descent: [(offset: Int, image: CGImage, top: Int)] = []
            for (offset, image) in frames.dropFirst().enumerated() {
                descent.append((offset: offset, image: image, top: opaqueTop(of: image)))
            }
            descent.sort { left, right in
                if left.top == right.top { return left.offset < right.offset }
                return left.top < right.top
            }
            // Start with precisely the normal standing sprite, avoiding a visual pop at the click.
            frames = [self.frames(for: .idle)[0]] + descent.map { $0.image }
        }
        if pose == .thinking {
            // The hand-to-chin gesture starts from the approved neutral standing pose.
            frames[0] = self.frames(for: .idle)[0]
        }
        cache[pose.atlas] = frames
        return frames
    }

    private static func opaqueTop(of image: CGImage) -> Int {
        let bitmap = NSBitmapImageRep(cgImage: image)
        let data = bitmap.bitmapData!
        let alpha = bitmap.bitmapFormat.contains(.alphaFirst) ? 0 : 3
        for y in 0..<image.height {
            for x in stride(from: 0, to: image.width, by: 4) {
                if data[y * bitmap.bytesPerRow + x * 4 + alpha] > 229 { return y }
            }
        }
        return image.height
    }

    private static func rowBands(in image: CGImage, rows: Int) -> [Range<Int>] {
        let bitmap = NSBitmapImageRep(cgImage: image)
        precondition(bitmap.bitsPerPixel == 32 && bitmap.bitsPerSample == 8 && !bitmap.isPlanar)
        let data = bitmap.bitmapData!
        let alpha = bitmap.bitmapFormat.contains(.alphaFirst) ? 0 : 3
        let counts = (0..<image.height).map { y in
            stride(from: 0, to: image.width, by: 2).reduce(0) { count, x in
                count + (data[y * bitmap.bytesPerRow + x * 4 + alpha] > 128 ? 1 : 0)
            }
        }
        let nominal = image.height / rows
        var boundaries = [0]
        for row in 1..<rows {
            let expected = nominal * row
            let search = (expected - nominal / 4)...(expected + nominal / 4)
            var gaps: [Range<Int>] = []
            var start: Int?
            for y in search {
                if counts[y] <= 2 { if start == nil { start = y } }
                else if let first = start { gaps.append(first..<y); start = nil }
            }
            if let first = start { gaps.append(first..<(search.upperBound + 1)) }
            let gap = gaps.min { abs(($0.lowerBound + $0.upperBound) / 2 - expected) < abs(($1.lowerBound + $1.upperBound) / 2 - expected) }
            boundaries.append(gap.map { ($0.lowerBound + $0.upperBound) / 2 } ?? expected)
        }
        boundaries.append(image.height)
        return (0..<rows).map { row in
            let occupied = (boundaries[row]..<boundaries[row + 1]).filter { counts[$0] > 2 }
            precondition(!occupied.isEmpty, "Empty Orbit sprite row")
            return occupied.first!..<(occupied.last! + 1)
        }
    }
}

/// Additive blending in an isolated layer keeps the shared silhouette opaque.
/// A normal pair of opacity modifiers would make the character translucent halfway through.
struct OrbitSpriteView: View {
    var pose: OrbitPose
    var elapsed: TimeInterval
    var moving: Bool

    var body: some View {
        let frames = OrbitSprites.frames(for: pose)
        let sample = pose.sample(elapsed: elapsed, moving: moving)
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            if sample.blend == 0 || sample.next == sample.current {
                context.draw(Image(decorative: frames[sample.current], scale: 1), in: rect)
                return
            }
            context.drawLayer { layer in
                layer.opacity = 1 - sample.blend
                layer.draw(Image(decorative: frames[sample.current], scale: 1), in: rect)
                layer.blendMode = .plusLighter
                layer.opacity = sample.blend
                layer.draw(Image(decorative: frames[sample.next], scale: 1), in: rect)
            }
        }.accessibilityHidden(true)
    }
}

/// Reserve the same space above every pose so a status change never shifts the model.
/// The desktop and settings preview share this presentation; raw clip previews stay unadorned.
struct OrbitMascotFigure: View {
    var pose: OrbitPose
    var elapsed: TimeInterval
    var moving: Bool
    var modelHeight: CGFloat
    var blendTransitions = false
    var clip: OrbitMeshyClip? = nil
    var useDefault = true

    private var badgeSize: CGFloat { min(44, max(28, modelHeight * 0.18)) }
    private var indicator: (symbol: String, color: Color)? {
        switch pose {
        case .speaking: ("text.bubble.fill", OrbitDesign.lime)
        case .clarify: ("questionmark.bubble.fill", OrbitDesign.lime)
        case .error: ("exclamationmark.triangle.fill", OrbitDesign.warning)
        default: nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.clear
                if let indicator {
                    Image(systemName: indicator.symbol)
                        .font(.system(size: badgeSize * 0.54, weight: .semibold))
                        .foregroundStyle(indicator.color)
                        .frame(width: badgeSize, height: badgeSize)
                        .background(OrbitDesign.carbon, in: Circle())
                        .overlay(Circle().strokeBorder(indicator.color.opacity(0.45), lineWidth: 1))
                        .shadow(color: indicator.color.opacity(0.2), radius: 8)
                        .id(pose)
                        .transition(.opacity)
                }
            }
            .frame(height: badgeSize + 8)
            .animation(moving ? .easeOut(duration: 0.18) : nil, value: pose)
            OrbitMascotArtwork(pose: pose, elapsed: elapsed, moving: moving,
                               blendTransitions: blendTransitions, clip: clip, useDefault: useDefault)
                .frame(width: modelHeight * 2 / 3, height: modelHeight)
        }
        .frame(width: modelHeight * 2 / 3)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct OrbitMascotView: View {
    @Bindable var model: PillModel
    @Bindable var animation: OrbitAnimationModel
    var runningCount: Int
    var pendingCount: Int
    var size: CGFloat
    var animations: Bool
    var showStatus: Bool
    var clipAssignments: [String: String]
    var onListen: () -> Void
    var onOpen: () -> Void
    var onSettings: () -> Void
    var onHide: () -> Void
    var onDragState: (Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: animations && !reduceMotion ? 1 / 60 : 1, paused: !animation.displayed)) { context in
            let date = context.date
            let pose = animation.pose(pillVisible: model.visible, pillState: model.state,
                                      runningCount: runningCount, pendingCount: pendingCount, at: date)
            let moving = animations && !reduceMotion
            let message = pose.message(runningCount: runningCount)
            let essential = pose == .listening || pose == .clarify || pose == .error
            let selectedClip = pose.meshClip(assignments: clipAssignments)
            VStack(spacing: 0) {
                OrbitMascotFigure(pose: pose, elapsed: animation.elapsed(for: pose, at: date),
                                  moving: moving, modelHeight: size, blendTransitions: true,
                                  clip: selectedClip, useDefault: false)
                    .padding(.top, 6)
                    .accessibilityHidden(true)
                Group {
                    if showStatus || essential {
                        HStack(spacing: 6) {
                            Image(systemName: pose == .error ? "exclamationmark.circle.fill" : pose == .listening ? "mic.fill" : "sparkle")
                                .font(.system(size: 9)).foregroundStyle(pose == .error ? OrbitDesign.error : OrbitDesign.lime)
                            Text(message).font(.system(size: 10, weight: .semibold))
                                .multilineTextAlignment(.center).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        }
                        .foregroundStyle(OrbitDesign.chalk).padding(.horizontal, 10).padding(.vertical, 7)
                        .background(OrbitDesign.carbon, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(OrbitDesign.line, lineWidth: 1))
                    }
                }.frame(height: 48)
            }
            .padding(.horizontal, 8).padding(.bottom, 4)
            .frame(width: max(size * 2 / 3 + 16, 168))
            .overlay {
                WindowDragSurface(onClick: onListen, onOpen: onOpen, onSettings: onSettings,
                                  onHide: onHide, onDragState: onDragState)
                    .accessibilityLabel("Orbit Aero. \(message). Clic per parlare, trascina per spostare, doppio clic per le sessioni.")
            }
            .help("Clic: ascolta o invia · Trascina: sposta Orbit · Doppio clic: sessioni · Esc: annulla")
            .onChange(of: pose, initial: true) { animation.syncPlayback(pose: pose, at: date) }
        }
    }
}

/// Native window dragging avoids coordinate feedback as the hosting view moves.
struct WindowDragSurface: NSViewRepresentable {
    var onClick: (() -> Void)? = nil
    var onOpen: (() -> Void)? = nil
    var onSettings: (() -> Void)? = nil
    var onHide: (() -> Void)? = nil
    var onDragState: (Bool) -> Void = { _ in }
    func makeNSView(context: Context) -> WindowDragView { WindowDragView() }
    func updateNSView(_ view: WindowDragView, context: Context) {
        view.onClick = onClick; view.onOpen = onOpen; view.onSettings = onSettings; view.onHide = onHide
        view.onDragState = onDragState
    }
}

final class WindowDragView: NSView {
    var onClick: (() -> Void)?
    private var pendingClick: Task<Void, Never>?
    private var moved = false
    var onOpen: (() -> Void)?
    var onSettings: (() -> Void)?
    var onHide: (() -> Void)?
    var onDragState: (Bool) -> Void = { _ in }
    private var startPointer: CGPoint?
    private var startOrigin: CGPoint?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { pendingClick?.cancel() }
    }
    override func isAccessibilityElement() -> Bool { onClick != nil }
    override func accessibilityRole() -> NSAccessibility.Role? { onClick != nil ? .button : nil }
    override func accessibilityPerformPress() -> Bool {
        guard let onClick else { return false }
        onClick(); return true
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        pendingClick?.cancel()
        moved = false
        if event.clickCount == 2, let onOpen { onOpen() }
        else {
            startPointer = window?.convertPoint(toScreen: event.locationInWindow)
            startOrigin = window?.frame.origin
        }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let window, let startPointer, let startOrigin else { return }
        let pointer = window.convertPoint(toScreen: event.locationInWindow)
        let deltaX = pointer.x - startPointer.x, deltaY = pointer.y - startPointer.y
        guard moved || deltaX * deltaX + deltaY * deltaY > 9 else { return }
        if !moved { moved = true; onDragState(true) }
        window.setFrameOrigin(CGPoint(x: startOrigin.x + pointer.x - startPointer.x,
                                      y: startOrigin.y + pointer.y - startPointer.y))
    }
    override func mouseUp(with event: NSEvent) {
        guard startPointer != nil else { return }
        startPointer = nil; startOrigin = nil
        if moved { onDragState(false) }
        else if let onClick {
            pendingClick = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval)) } catch { return }
                guard !Task.isCancelled else { return }
                onClick()
            }
        }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard onSettings != nil else { return nil }
        let menu = NSMenu()
        if onClick != nil {
            let item = menu.addItem(withTitle: "Parla con Orbit", action: #selector(listen), keyEquivalent: "")
            item.target = self
            menu.addItem(.separator())
        }
        for (title, action) in [("Mostra o nascondi le sessioni", #selector(openSessions)),
                                ("Impostazioni della mascotte…", #selector(openSettings)),
                                ("Nascondi Orbit", #selector(hideMascot))] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
        }
        return menu
    }
    @objc private func listen() { onClick?() }
    @objc private func openSessions() { onOpen?() }
    @objc private func openSettings() { onSettings?() }
    @objc private func hideMascot() { onHide?() }
}
