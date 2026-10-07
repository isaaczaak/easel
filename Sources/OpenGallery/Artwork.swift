import AppKit

struct Artwork: Identifiable, Hashable {
    let id: String
    let w: Int
    let h: Int
    let oid: Int
    let title: String
    let artist: String
    let date: String
    let kind: String
    /// Dominant colors from scripts/analyze_colors.py (PaletteColor raw values).
    let palette: [String]?
    /// Flagged by NGA's keywords or the CLIP pass in scripts/detect_nudity.py.
    let nude: Bool?
    /// e.g. "oil on canvas".
    let medium: String?
    /// The lead artist's nationality and life dates, e.g. "American, 1796 - 1872".
    let bio: String?
    /// NGA's movement tags (ArtMovement raw values); most works have none.
    let movements: [String]?

    /// NGA's open access policy, which releases these images under CC0.
    static let openAccessPolicy = URL(string: "https://www.nga.gov/terms-and-notices#open-access")!

    /// NGA's artwork page. The legacy URL redirects to the current slugged page.
    var pageURL: URL {
        URL(string: "https://www.nga.gov/collection/art-object-page.\(oid).html")!
    }

    /// Pixel width that covers a screen of `pixelSize` once the wallpaper is
    /// scaled to fill (the excess is cropped). Never larger than the original.
    /// Landscape artworks fill the screen; narrower ones are shown whole on a
    /// gallery wall (GalleryWall).
    var fillsScreen: Bool { Double(w) / Double(h) >= 1.2 }

    func imageWidth(covering pixelSize: CGSize) -> Int {
        let scale = max(pixelSize.width / CGFloat(w), pixelSize.height / CGFloat(h))
        return min(w, Int((CGFloat(w) * scale).rounded(.up)))
    }

    func imageURL(width: Int) -> URL {
        URL(string: "https://api.nga.gov/iiif/\(id)/full/\(width),/0/default.jpg")!
    }

    /// Title for the menu: parenthetical subtitles and bracketed plate
    /// numbers removed, capped so the menu keeps a steady width.
    var menuTitle: String {
        let cleaned = title
            .replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.truncate(cleaned.isEmpty ? title : cleaned)
    }

    var menuByline: String {
        Self.truncate([artist, date].filter { !$0.isEmpty }.joined(separator: ", "))
    }

    private static func truncate(_ text: String, limit: Int = 36) -> String {
        guard text.count > limit else { return text }
        let cut = text.prefix(limit)
        let atWord = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return atWord.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)) + "…"
    }
}

/// Classifications offered as filters, in menu order.
enum ArtKind: String, CaseIterable, Identifiable {
    case painting, drawing, print, photograph, sculpture

    var id: String { rawValue }
    var label: String { rawValue.capitalized + (self == .sculpture ? "" : "s") }
}

/// Dominant-color filters, in menu order.
/// Which shapes of artwork to show.
enum Orientation: String, CaseIterable, Identifiable {
    case any, landscape, portrait

    var id: String { rawValue }
    var label: String {
        switch self {
        case .any: return "Any"
        case .landscape: return "Landscape"
        case .portrait: return "Portrait & square"
        }
    }

    func includes(fillsScreen: Bool) -> Bool {
        switch self {
        case .any: return true
        case .landscape: return fillsScreen
        case .portrait: return !fillsScreen
        }
    }
}

/// Art movements, in historical order. Raw values are NGA's style terms.
enum ArtMovement: String, CaseIterable, Identifiable {
    case renaissance = "Renaissance", baroque = "Baroque", rococo = "Rococo"
    case neoclassic = "Neoclassic", romantic = "Romantic", realist = "Realist"
    case impressionist = "Impressionist", postImpressionist = "Post-Impressionist", naive = "Naive"

    var id: String { rawValue }
}

enum PaletteColor: String, CaseIterable, Identifiable {
    case red, orange, yellow, green, blue, purple, brown, mono

    var id: String { rawValue }

    var label: String {
        self == .mono ? "Black & White" : rawValue.capitalized
    }

    /// A small filled circle in this color, for the menu.
    var swatch: NSImage {
        let rgb: (CGFloat, CGFloat, CGFloat)
        switch self {
        case .red: rgb = (0.80, 0.20, 0.18)
        case .orange: rgb = (0.93, 0.52, 0.16)
        case .yellow: rgb = (0.95, 0.78, 0.20)
        case .green: rgb = (0.30, 0.58, 0.30)
        case .blue: rgb = (0.22, 0.42, 0.75)
        case .purple: rgb = (0.52, 0.32, 0.66)
        case .brown: rgb = (0.52, 0.36, 0.22)
        case .mono: rgb = (0.55, 0.55, 0.55)
        }
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            NSColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            if self == .mono {  // half black, half white
                NSColor.white.setFill()
                let half = NSBezierPath()
                half.appendArc(withCenter: NSPoint(x: 6, y: 6), radius: 5, startAngle: 90, endAngle: 270)
                half.close()
                half.fill()
            }
            NSColor.black.withAlphaComponent(0.25).setStroke()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).stroke()
            return true
        }
        image.isTemplate = false
        return image
    }
}
