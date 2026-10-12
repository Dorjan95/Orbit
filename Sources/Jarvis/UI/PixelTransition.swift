import SwiftUI

/// Pixel reveal follows the deterministic radial pattern used by EnvHalo.
struct OrbitPixelMask: Shape {
    var progress: CGFloat
    var animatableData: CGFloat { get { progress } set { progress = newValue } }
    func path(in rect: CGRect) -> Path {
        if progress >= 1 { return Path(rect) }
        if progress <= 0 { return Path() }
        var path = Path()
        let step: CGFloat = 10
        let columns = max(Int(ceil(rect.width / step)), 1)
        let rows = max(Int(ceil(rect.height / step)), 1)
        for row in 0..<rows {
            for col in 0..<columns {
                let cell = CGRect(x: rect.minX + CGFloat(col) * step, y: rect.minY + CGFloat(row) * step,
                    width: min(step, rect.width - CGFloat(col) * step), height: min(step, rect.height - CGFloat(row) * step))
                let dx = (cell.midX - rect.midX) / max(rect.width, 1)
                let dy = (cell.midY - rect.midY) / max(rect.height, 1)
                let radial = min(sqrt(dx * dx + dy * dy) / 0.707, 1)
                let random = CGFloat((col * 37 + row * 61 + col * row * 17) % 101) / 100
                let threshold = min(radial * 0.92 + random * 0.08, 1) * 0.78
                let scale = min(max((progress - threshold) / 0.22, 0), 1)
                if scale > 0 { path.addRect(cell.insetBy(dx: cell.width * (1 - scale) / 2, dy: cell.height * (1 - scale) / 2)) }
            }
        }
        return path
    }
}

struct OrbitPixelModifier: AnimatableModifier {
    nonisolated var progress: CGFloat
    nonisolated var animatableData: CGFloat { get { progress } set { progress = newValue } }
    func body(content: Content) -> some View { content.mask(OrbitPixelMask(progress: progress)) }
}

extension AnyTransition {
    static var orbitPixels: AnyTransition {
        .modifier(active: OrbitPixelModifier(progress: 0), identity: OrbitPixelModifier(progress: 1))
    }
}
