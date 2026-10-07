import AppKit

/// Menu bar glyph: a rounded panel inside a moulding, like the app icon. A
/// template image, so macOS tints it for light/dark menu bars.
enum MenuBarIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 20, height: 16), flipped: false) { _ in
            let frame = NSRect(x: 1.5, y: 1.5, width: 17, height: 13)

            let outer = NSBezierPath(roundedRect: frame.insetBy(dx: 0.75, dy: 0.75), xRadius: 3.5, yRadius: 3.5)
            outer.lineWidth = 1.5
            outer.stroke()

            let panel = NSBezierPath(roundedRect: frame.insetBy(dx: 3.5, dy: 3.5), xRadius: 1.5, yRadius: 1.5)
            panel.lineWidth = 1
            panel.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }()
}
