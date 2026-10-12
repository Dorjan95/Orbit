import Foundation

/// AppKit screen coordinates can be negative on secondary displays.
enum DesktopLayout {
    static func fittedFrame(origin: CGPoint?, size: CGSize, screens: [CGRect], fallback: CGRect) -> CGRect {
        let proposed = origin.map { CGRect(origin: $0, size: size) }
        let visible = proposed.flatMap { proposed in
            screens.max(by: { intersectionArea(proposed, $0) < intersectionArea(proposed, $1) })
                .flatMap { intersectionArea(proposed, $0) > 0 ? $0 : nil }
        } ?? fallback
        let safeSize = CGSize(width: min(size.width, visible.width), height: min(size.height, visible.height))
        let point = proposed.map { $0.origin } ?? CGPoint(x: visible.maxX - safeSize.width - 24, y: visible.minY + 24)
        let useDefault = proposed != nil && !screens.contains { intersectionArea(proposed!, $0) > 0 }
        let candidate = useDefault ? CGPoint(x: visible.maxX - safeSize.width - 24, y: visible.minY + 24) : point
        return CGRect(x: min(max(candidate.x, visible.minX), visible.maxX - safeSize.width),
                      y: min(max(candidate.y, visible.minY), visible.maxY - safeSize.height),
                      width: safeSize.width, height: safeSize.height)
    }

    static func pillFrame(visible: CGRect, size: CGSize) -> CGRect {
        CGRect(x: visible.midX - size.width / 2, y: visible.maxY - 12 - size.height, width: size.width, height: size.height)
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }
}
