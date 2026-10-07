import Foundation

/// Downloads artwork images into ~/Library/Caches and keeps the newest few.
final class ImageCache {
    private let directory: URL
    /// How many downloaded images to keep: enough for a few ready ahead and
    /// recent history on two displays.
    private let limit = 30

    /// Where downloaded artwork lives.
    static var directory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "OpenGallery", isDirectory: true)
    }

    init() {
        directory = Self.directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Local file for `artwork` sized for `pixelSize`, downloading it if needed.
    /// Portrait and square works come back already hung on a gallery wall.
    /// The filename includes the size so a new display gets a fresh file (macOS
    /// caches wallpapers by path).
    func file(for artwork: Artwork, covering pixelSize: CGSize) async throws -> URL {
        let hung = !artwork.fillsScreen
        let width = hung ? GalleryWall.imageWidth(of: artwork, on: pixelSize) : artwork.imageWidth(covering: pixelSize)
        let name = hung ? "\(artwork.id)-wall-\(Int(pixelSize.width))x\(Int(pixelSize.height))" : "\(artwork.id)-\(width)"
        let local = directory.appendingPathComponent(name + ".jpg")

        if FileManager.default.fileExists(atPath: local.path) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: local.path)
            return local
        }

        let (temp, response) = try await URLSession.shared.download(from: artwork.imageURL(width: width))
        defer { try? FileManager.default.removeItem(at: temp) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.mimeType == "image/jpeg"
        else {
            throw URLError(.badServerResponse)
        }
        try? FileManager.default.removeItem(at: local)
        if hung {
            try await GalleryWall.renderInTurn(temp, size: pixelSize, to: local)
        } else {
            try FileManager.default.moveItem(at: temp, to: local)
        }
        prune(keeping: local)
        return local
    }

    private func prune(keeping keep: URL) {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys)
        else { return }

        let sorted = files.filter { $0.pathExtension == "jpg" }.sorted {
            let a = (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            return a > b
        }
        for file in sorted.dropFirst(limit) where file != keep {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
