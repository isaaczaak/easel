// Renders the app icon: a recessed plaster panel with a raised moulding,
// cream on cream, like the panelled walls of a gallery.
// Writes Resources/AppIcon.icns and docs/icon.png.
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

func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// A step down into the wall. Light comes from above, so the step casts a
/// shadow along its top inner edge and catches light along its bottom one.
func recess(_ ctx: CGContext, _ rect: CGRect, _ radius: CGFloat, depth: CGFloat, strength: CGFloat) {
    let path = rounded(rect, radius)
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.setShadow(offset: CGSize(width: 0, height: -depth), blur: depth * 1.6, color: color(0x4A3A28, strength))
    let surround = CGMutablePath()
    surround.addRect(rect.insetBy(dx: -80, dy: -80))
    surround.addPath(path)
    ctx.addPath(surround)
    ctx.setFillColor(color(0x000000))
    ctx.fillPath(using: .evenOdd)
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.addPath(rounded(rect.offsetBy(dx: 0, dy: 2.5), radius))
    ctx.setLineWidth(3)
    ctx.setStrokeColor(color(0xFFFFFF, 0.55))
    ctx.strokePath()
    ctx.restoreGState()
}

/// A raised moulding of `width` around `rect`: lit on top, shadowed below.
func bead(_ ctx: CGContext, _ rect: CGRect, _ radius: CGFloat, width: CGFloat) {
    let ring = CGMutablePath()
    ring.addPath(rounded(rect, radius))
    ring.addPath(rounded(rect.insetBy(dx: width, dy: width), radius - width))

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 7, color: color(0x4A3A28, 0.30))
    ctx.addPath(ring)
    ctx.setFillColor(color(0xEFE7DB))
    ctx.fillPath(using: .evenOdd)
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(ring)
    ctx.clip(using: .evenOdd)
    let gradient = CGGradient(colorsSpace: space, colors: [color(0xFFFCF6), color(0xE6DCCD), color(0xD9CDBB)] as CFArray,
                              locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.minY), options: [])
    // Crest of the moulding
    ctx.addPath(rounded(rect.insetBy(dx: width / 2, dy: width / 2), radius - width / 2))
    ctx.setStrokeColor(color(0xFFFFFF, 0.45))
    ctx.setLineWidth(1.5)
    ctx.strokePath()
    ctx.restoreGState()
}

/// Draws on a 1024×1024 canvas (origin bottom-left). Light comes from above.
func drawIcon(_ ctx: CGContext) {
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = rounded(body, 185)

    // Icon drop shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0x000000, 0.30))
    ctx.addPath(squircle)
    ctx.setFillColor(color(0xEDE6DA))
    ctx.fillPath()
    ctx.restoreGState()

    // Wall: warm plaster, lit from the upper left.
    linear(ctx, squircle, [color(0xF6F0E6), color(0xE3D8C8)], from: CGPoint(x: 0, y: body.maxY), to: CGPoint(x: 0, y: body.minY))
    radial(ctx, squircle, [color(0xFFFDF8, 0.75), color(0xFFFDF8, 0)], center: CGPoint(x: 420, y: 900), radius: 620)

    // Panel: a raised moulding, a shallow first step, then the recessed field.
    let panel = body.insetBy(dx: 130, dy: 130)
    bead(ctx, panel, 82, width: 16)
    let field = panel.insetBy(dx: 30, dy: 30)
    recess(ctx, field.insetBy(dx: -8, dy: -8), 60, depth: 4, strength: 0.18)
    linear(ctx, rounded(field, 52), [color(0xEDE5D8), color(0xF7F2EA)],
           from: CGPoint(x: 0, y: field.maxY), to: CGPoint(x: 0, y: field.minY))
    recess(ctx, field, 52, depth: 10, strength: 0.32)

    // Plaster grain and a soft vignette over everything.
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    ctx.setBlendMode(.overlay)
    ctx.setAlpha(0.07)
    ctx.draw(grain, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
    ctx.restoreGState()
    radial(ctx, squircle, [color(0x000000, 0), color(0x5A4630, 0.14)], center: CGPoint(x: 512, y: 560), radius: 660)

    // Icon edge: faint highlight on the top rim.
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    ctx.addPath(rounded(body.insetBy(dx: 1.5, dy: 1.5), 184))
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
try! png(size: 256).write(to: root.appendingPathComponent("docs/icon.png"))

let out = root.appendingPathComponent("Resources/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try! iconutil.run()
iconutil.waitUntilExit()
print("wrote \(out.path)")
