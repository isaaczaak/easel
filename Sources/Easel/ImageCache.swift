import Foundation

/// Downloads artwork images into ~/Library/Caches and keeps the newest few.
final class ImageCache {
    private let directory: URL
    private let limit: Int

    init(limit: Int = 20) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Easel", isDirectory: true)
        self.limit = limit
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Local file for `artwork` sized for `pixelSize`, downloading it if needed.
    /// The filename includes the size so a new display gets a fresh file (macOS
    /// caches wallpapers by path).
    func file(for artwork: Artwork, covering pixelSize: CGSize) async throws -> URL {
        let width = artwork.imageWidth(covering: pixelSize)
        let remote = artwork.imageURL(width: width)
        let local = directory.appendingPathComponent("\(artwork.id)-\(width).jpg")

        if FileManager.default.fileExists(atPath: local.path) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: local.path)
            return local
        }

        let (temp, response) = try await URLSession.shared.download(from: remote)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.mimeType == "image/jpeg"
        else {
            throw URLError(.badServerResponse)
        }
        try? FileManager.default.removeItem(at: local)
        try FileManager.default.moveItem(at: temp, to: local)
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
