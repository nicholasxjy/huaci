import CoreGraphics

/// Places the result window next to the mouse while keeping it fully inside the
/// visible frame of the screen under the mouse. Uses AppKit's bottom-left
/// coordinate space.
public enum PopupPositioner {
    public static let offset = CGPoint(x: 12, y: 16)

    public static func frame(size: CGSize, mouse: CGPoint, screens: [CGRect]) -> CGRect {
        guard let screen = screen(containing: mouse, in: screens) else {
            return CGRect(origin: CGPoint(x: mouse.x, y: mouse.y - size.height), size: size)
        }
        let width = min(size.width, screen.width)
        let height = min(size.height, screen.height)

        var x = mouse.x + offset.x
        if x + width > screen.maxX { x = mouse.x - offset.x - width }
        x = clamp(x, screen.minX, screen.maxX - width)

        // Prefer below the mouse; flip above when there is no room.
        var y = mouse.y - offset.y - height
        if y < screen.minY { y = mouse.y + offset.y }
        y = clamp(y, screen.minY, screen.maxY - height)

        return CGRect(x: x, y: y, width: width, height: height)
    }

    static func screen(containing point: CGPoint, in screens: [CGRect]) -> CGRect? {
        if let match = screens.first(where: { $0.insetBy(dx: -1, dy: -1).contains(point) }) { return match }
        return screens.min { distance(point, $0) < distance(point, $1) }
    }

    private static func distance(_ point: CGPoint, _ rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }

    private static func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        min(max(value, low), max(low, high))
    }
}
