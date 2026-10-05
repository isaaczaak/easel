import AppKit

/// Menu bar glyph: a framed landscape. A template image, so macOS tints it
/// for light/dark menu bars.
enum MenuBarIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 20, height: 16), flipped: false) { _ in
            let frame = NSRect(x: 1, y: 1.5, width: 18, height: 13)

            // Outer moulding and inner lip
            let outer = NSBezierPath(rect: frame.insetBy(dx: 0.9, dy: 0.9))
            outer.lineWidth = 1.8
            outer.stroke()
            let canvas = frame.insetBy(dx: 3.6, dy: 3.6)
            let lip = NSBezierPath(rect: canvas)
            lip.lineWidth = 0.8
            lip.stroke()

            // Corner rosettes
            for x in [frame.minX + 0.9, frame.maxX - 0.9] {
                for y in [frame.minY + 0.9, frame.maxY - 0.9] {
                    NSBezierPath(ovalIn: NSRect(x: x - 1.4, y: y - 1.4, width: 2.8, height: 2.8)).fill()
                }
            }

            // Landscape: sun and a hill
            NSBezierPath(ovalIn: NSRect(x: canvas.maxX - 3.6, y: canvas.maxY - 3.2, width: 2.2, height: 2.2)).fill()
            let hill = NSBezierPath()
            hill.move(to: NSPoint(x: canvas.minX, y: canvas.minY + 1.6))
            hill.curve(to: NSPoint(x: canvas.maxX, y: canvas.minY + 1.2),
                       controlPoint1: NSPoint(x: canvas.minX + 3, y: canvas.minY + 4.4),
                       controlPoint2: NSPoint(x: canvas.maxX - 4, y: canvas.minY))
            hill.line(to: NSPoint(x: canvas.maxX, y: canvas.minY))
            hill.line(to: NSPoint(x: canvas.minX, y: canvas.minY))
            hill.close()
            hill.fill()
            return true
        }
        image.isTemplate = true
        return image
    }()
}
