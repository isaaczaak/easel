import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Portrait and square artworks would lose most of the picture if cropped to
/// fill a wide screen, so they're shown whole, hung on a warm plaster wall
/// like the app icon. This renders that as one screen-sized image.
enum GalleryWall {
    /// How much of the screen's height the artwork takes up.
    static let heightShare: CGFloat = 0.78

    /// Size to download `artwork` at so it's sharp when hung on a screen of
    /// `pixelSize`.
    static func imageWidth(of artwork: Artwork, on pixelSize: CGSize) -> Int {
        let fit = min(pixelSize.height * heightShare / CGFloat(artwork.h),
                      pixelSize.width * 0.9 / CGFloat(artwork.w))
        return min(artwork.w, Int((CGFloat(artwork.w) * fit).rounded(.up)))
    }

    /// Writes a JPEG of the artwork at `source` hung on the wall, sized
    /// `pixelSize`, to `destination`.
    static func render(_ source: URL, size pixelSize: CGSize, to destination: URL) throws {
        guard let input = CGImageSourceCreateWithURL(source as CFURL, nil),
              let art = CGImageSourceCreateImageAtIndex(input, 0, nil)
        else { throw CocoaError(.fileReadCorruptFile) }

        let width = Int(pixelSize.width), height = Int(pixelSize.height)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw CocoaError(.fileWriteUnknown) }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)

        // Wall: warm plaster, a little lighter at the top.
        let wall = CGGradient(colorsSpace: space, colors: [
            CGColor(srgbRed: 0.949, green: 0.925, blue: 0.886, alpha: 1),
            CGColor(srgbRed: 0.867, green: 0.827, blue: 0.765, alpha: 1),
        ] as CFArray, locations: nil)!
        ctx.drawLinearGradient(wall, start: CGPoint(x: 0, y: bounds.maxY), end: CGPoint(x: 0, y: 0), options: [])

        // Artwork: whole, centred and hung slightly high, with a soft shadow.
        let scale = min(bounds.height * heightShare / CGFloat(art.height),
                        bounds.width * 0.9 / CGFloat(art.width))
        let size = CGSize(width: CGFloat(art.width) * scale, height: CGFloat(art.height) * scale)
        let frame = CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2 + bounds.height * 0.02,
                           width: size.width, height: size.height).integral
        let unit = bounds.height / 900  // shadow scales with the screen
        ctx.setShadow(offset: CGSize(width: 0, height: -14 * unit), blur: 40 * unit,
                      color: CGColor(gray: 0, alpha: 0.35))
        ctx.interpolationQuality = .high
        ctx.draw(art, in: frame)

        guard let image = ctx.makeImage(),
              let output = CGImageDestinationCreateWithURL(destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(output, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(output) else { throw CocoaError(.fileWriteUnknown) }
    }
}
