// Renders the app icon: a framed, matted painting (Monet's The Japanese
// Footbridge, NGA, CC0) hanging on a softly lit gallery wall.
// Writes Resources/AppIcon.icns and Resources/AppIcon-preview.png.
//   swift scripts/make_icon.swift
import AppKit

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let space = CGColorSpaceCreateDeviceRGB()

func linear(_ ctx: CGContext, _ path: CGPath, _ colors: [CGColor], _ locations: [CGFloat]? = nil,
            from: CGPoint, to: CGPoint) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
    ctx.drawLinearGradient(gradient, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

func radial(_ ctx: CGContext, _ path: CGPath, _ colors: [CGColor], center: CGPoint, radius: CGFloat) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!
    ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius,
                           options: [.drawsAfterEndLocation])
    ctx.restoreGState()
}

/// A rectangular ring (outer minus inner), for bevels and frame faces.
func ring(_ outer: CGRect, _ inner: CGRect) -> CGPath {
    let path = CGMutablePath()
    path.addRect(outer)
    path.addRect(inner)
    return path
}

/// One edge of a ring as a trapezoid, so each side can be lit differently.
func bevelSide(_ outer: CGRect, _ inner: CGRect, _ side: Int) -> CGPath {
    let o = [CGPoint(x: outer.minX, y: outer.maxY), CGPoint(x: outer.maxX, y: outer.maxY),
             CGPoint(x: outer.maxX, y: outer.minY), CGPoint(x: outer.minX, y: outer.minY)]
    let i = [CGPoint(x: inner.minX, y: inner.maxY), CGPoint(x: inner.maxX, y: inner.maxY),
             CGPoint(x: inner.maxX, y: inner.minY), CGPoint(x: inner.minX, y: inner.minY)]
    let a = side, b = (side + 1) % 4  // 0 top, 1 right, 2 bottom, 3 left
    let path = CGMutablePath()
    path.addLines(between: [o[a], o[b], i[b], i[a]])
    path.closeSubpath()
    return path
}

/// Fine plaster grain, generated once.
let grain: CGImage = {
    let size = 512
    var pixels = [UInt8](repeating: 0, count: size * size)
    var seed: UInt64 = 0x9E3779B97F4A7C15
    for index in pixels.indices {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        pixels[index] = UInt8(truncatingIfNeeded: seed >> 56)
    }
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: size,
                   space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [], provider: provider,
                   decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}()

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let painting = NSImage(contentsOf: root.appendingPathComponent("Resources/icon-painting.jpg"))!
    .cgImage(forProposedRect: nil, context: nil, hints: nil)!

/// Draws on a 1024×1024 canvas (origin bottom-left). Light comes from above.
func drawIcon(_ ctx: CGContext) {
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Icon drop shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0x000000, 0.32))
    ctx.addPath(squircle)
    ctx.setFillColor(color(0xEDE6DA))
    ctx.fillPath()
    ctx.restoreGState()

    // Wall: warm plaster, lit by a spotlight above the picture.
    linear(ctx, squircle, [color(0xF7F2EA), color(0xE4DACB)], from: CGPoint(x: 0, y: body.maxY), to: CGPoint(x: 0, y: body.minY))
    radial(ctx, squircle, [color(0xFFFDF8, 0.85), color(0xFFFDF8, 0)],
           center: CGPoint(x: 512, y: 860), radius: 520)
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    ctx.setBlendMode(.overlay)
    ctx.setAlpha(0.06)
    ctx.draw(grain, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
    ctx.restoreGState()
    // Edge vignette
    radial(ctx, squircle, [color(0x000000, 0), color(0x5A4630, 0.16)], center: CGPoint(x: 512, y: 560), radius: 640)

    // Frame geometry
    let frame = CGRect(x: 512 - 252, y: 512 - 240, width: 504, height: 504)
    let frameInner = frame.insetBy(dx: 30, dy: 30)
    let opening = frameInner.insetBy(dx: 64, dy: 64)  // mat window
    let bevel: CGFloat = 9

    // Cast shadows: wide and soft, then tight contact shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -34), blur: 60, color: color(0x3B2A18, 0.40))
    ctx.setFillColor(color(0x161616))
    ctx.fill(frame)
    ctx.restoreGState()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 10, color: color(0x000000, 0.45))
    ctx.setFillColor(color(0x161616))
    ctx.fill(frame)
    ctx.restoreGState()

    // Frame face: black lacquer, each side lit for a rounded profile.
    let face = [(0, [color(0x4A4A4A), color(0x1C1C1C)]), (1, [color(0x262626), color(0x111111)]),
                (2, [color(0x0A0A0A), color(0x1A1A1A)]), (3, [color(0x303030), color(0x151515)])]
    for (side, colors) in face {
        let path = bevelSide(frame, frameInner, side)
        let box = path.boundingBox
        let (from, to): (CGPoint, CGPoint) = side % 2 == 0
            ? (CGPoint(x: 0, y: side == 0 ? box.maxY : box.minY), CGPoint(x: 0, y: side == 0 ? box.minY : box.maxY))
            : (CGPoint(x: side == 3 ? box.minX : box.maxX, y: 0), CGPoint(x: side == 3 ? box.maxX : box.minX, y: 0))
        linear(ctx, path, colors, from: from, to: to)
    }
    // Specular line along the frame's outer top edge, and a fine inner lip.
    ctx.setStrokeColor(color(0xFFFFFF, 0.28))
    ctx.setLineWidth(2)
    ctx.move(to: CGPoint(x: frame.minX + 2, y: frame.maxY - 1.5))
    ctx.addLine(to: CGPoint(x: frame.maxX - 2, y: frame.maxY - 1.5))
    ctx.strokePath()
    ctx.setStrokeColor(color(0x000000, 0.9))
    ctx.setLineWidth(2)
    ctx.stroke(frameInner)

    // Mat: off-white rag board, slightly shaded by the frame lip at the top.
    linear(ctx, CGPath(rect: frameInner, transform: nil), [color(0xEFEBE3), color(0xFAF8F3)],
           from: CGPoint(x: 0, y: frameInner.maxY), to: CGPoint(x: 0, y: frameInner.minY))
    ctx.saveGState()
    ctx.clip(to: frameInner)
    ctx.setShadow(offset: CGSize(width: 0, height: -5), blur: 12, color: color(0x000000, 0.35))
    ctx.addPath(ring(frameInner.insetBy(dx: -40, dy: -40), frameInner))
    ctx.setFillColor(color(0x000000))
    ctx.fillPath(using: .evenOdd)
    ctx.restoreGState()

    // Painting, recessed behind the mat window.
    let art = opening.insetBy(dx: -2, dy: -2)
    ctx.saveGState()
    ctx.clip(to: art)
    ctx.draw(painting, in: art)
    ctx.restoreGState()
    // Mat edge shadow falling onto the painting.
    ctx.saveGState()
    ctx.clip(to: opening)
    ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 8, color: color(0x000000, 0.45))
    ctx.addPath(ring(opening.insetBy(dx: -30, dy: -30), opening))
    ctx.setFillColor(color(0x000000))
    ctx.fillPath(using: .evenOdd)
    ctx.restoreGState()

    // Bevel-cut mat edge: white core, lit top-left.
    let bevelOuter = opening.insetBy(dx: -bevel, dy: -bevel)
    let bevelShades: [CGFloat] = [1.0, 0.86, 0.80, 0.95]
    for side in 0..<4 {
        ctx.addPath(bevelSide(bevelOuter, opening, side))
        let v = bevelShades[side]
        ctx.setFillColor(CGColor(red: v, green: v * 0.985, blue: v * 0.96, alpha: 1))
        ctx.fillPath()
    }

    // Glass: a soft diagonal glare across the upper left.
    let glass = CGPath(rect: frameInner, transform: nil)
    ctx.saveGState()
    ctx.addPath(glass)
    ctx.clip()
    let glare = CGMutablePath()
    glare.move(to: CGPoint(x: frameInner.minX, y: frameInner.maxY))
    glare.addLine(to: CGPoint(x: frameInner.minX + 250, y: frameInner.maxY))
    glare.addLine(to: CGPoint(x: frameInner.minX, y: frameInner.maxY - 300))
    glare.closeSubpath()
    linear(ctx, glare, [color(0xFFFFFF, 0.22), color(0xFFFFFF, 0)],
           from: CGPoint(x: frameInner.minX, y: frameInner.maxY),
           to: CGPoint(x: frameInner.minX + 140, y: frameInner.maxY - 160))
    ctx.restoreGState()

    // Icon edge: faint highlight on the top rim.
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 184, cornerHeight: 184, transform: nil))
    ctx.setLineWidth(3)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    linear(ctx, squircle, [color(0xFFFFFF, 0.7), color(0xFFFFFF, 0)], from: CGPoint(x: 0, y: body.maxY),
           to: CGPoint(x: 0, y: body.midY))
    ctx.restoreGState()
}

func png(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    drawIcon(ctx)
    return rep.representation(using: .png, properties: [:])!
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! png(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! png(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try! png(size: 1024).write(to: root.appendingPathComponent("Resources/AppIcon-preview.png"))

let out = root.appendingPathComponent("Resources/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try! iconutil.run()
iconutil.waitUntilExit()
print("wrote \(out.path)")
