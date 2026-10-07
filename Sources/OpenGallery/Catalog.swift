import Foundation

/// The bundled artwork list, kept packed in memory: about 11 MB for 62,000
/// works, against 200+ MB as decoded JSON. Filtering reads the small numeric
/// fields in place; an `Artwork` with its text is built only when shown.
///
/// Format (little-endian), written by scripts/pack_catalog.swift:
///   "OGC1", count: UInt32,
///   kind, palette and movement name tables (UInt8 count, then UInt8-length UTF-8 names),
///   stringsLength: UInt32,
///   count × 64-byte records:
///     uuid[16], w, h, oid: UInt32, kind: UInt8, nude: UInt8,
///     palette mask: UInt16, movement mask: UInt16,
///     title, artist, date, medium, bio: (offset: UInt32, length: UInt16)
///   then the UTF-8 strings.
final class Catalog {
    let count: Int
    let kinds: [String]
    let palettes: [String]
    let movements: [String]

    private let data: Data
    private let recordsStart: Int
    private let stringsStart: Int
    private let indexByID: [UUID: Int32]
    private static let recordSize = 64

    /// The catalog bundled with the app, or an empty one if it's missing.
    static func loadBundled() -> Catalog {
        let data: Data? = autoreleasepool {  // frees the compressed copy straight away
            guard let url = Bundle.main.url(forResource: "catalog.bin", withExtension: "lzma"),
                  let compressed = NSData(contentsOf: url)
            else { return nil }
            return try? compressed.decompressed(using: .lzma) as Data
        }
        guard let data, let catalog = Catalog(data) else {
            NSLog("OpenGallery: bundled catalog missing or invalid")
            return Catalog(Data("OGC1".utf8) + Data(count: 4 + 3 + 4))!
        }
        return catalog
    }

    init?(_ data: Data) {
        guard data.count >= 15, data.prefix(4) == Data("OGC1".utf8) else { return nil }
        self.data = data
        var offset = 4
        func readInt<T: FixedWidthInteger>(_ type: T.Type) -> T {
            defer { offset += MemoryLayout<T>.size }
            return T(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) })
        }
        func readTable() -> [String] {
            (0..<Int(readInt(UInt8.self))).map { _ in
                let length = Int(readInt(UInt8.self))
                defer { offset += length }
                return String(decoding: data[(data.startIndex + offset)..<(data.startIndex + offset + length)], as: UTF8.self)
            }
        }
        count = Int(readInt(UInt32.self))
        kinds = readTable()
        palettes = readTable()
        movements = readTable()
        let stringsLength = Int(readInt(UInt32.self))
        recordsStart = offset
        stringsStart = offset + count * Self.recordSize
        guard data.count == stringsStart + stringsLength else { return nil }

        var index: [UUID: Int32] = [:]
        let records = offset, total = count, size = Self.recordSize
        index.reserveCapacity(total)
        data.withUnsafeBytes { bytes in
            for i in 0..<total {
                let uuid = bytes.loadUnaligned(fromByteOffset: records + i * size, as: uuid_t.self)
                index[UUID(uuid: uuid)] = Int32(i)
            }
        }
        indexByID = index
    }

    // MARK: Compact fields, for filtering

    func kind(at i: Int) -> Int { Int(field(i, 28, UInt8.self)) }
    func isNude(at i: Int) -> Bool { field(i, 29, UInt8.self) != 0 }
    func paletteMask(at i: Int) -> UInt16 { field(i, 30, UInt16.self) }
    func movementMask(at i: Int) -> UInt16 { field(i, 32, UInt16.self) }
    func fillsScreen(at i: Int) -> Bool { Double(field(i, 16, UInt32.self)) / Double(field(i, 20, UInt32.self)) >= 1.2 }

    /// Bit mask for `names` within `table` (kinds, palettes or movements).
    static func mask(_ names: Set<String>, in table: [String]) -> UInt16 {
        table.enumerated().reduce(0) { names.contains($1.element) ? $0 | (1 << UInt16($1.offset)) : $0 }
    }

    // MARK: Whole artworks

    func index(of id: String) -> Int? {
        UUID(uuidString: id).flatMap { indexByID[$0] }.map(Int.init)
    }

    func artwork(id: String) -> Artwork? { index(of: id).map(artwork(at:)) }

    func artwork(at i: Int) -> Artwork {
        let uuid = field(i, 0, uuid_t.self)
        let palette = paletteMask(at: i), movement = movementMask(at: i)
        return Artwork(
            id: UUID(uuid: uuid).uuidString.lowercased(),
            w: Int(field(i, 16, UInt32.self)), h: Int(field(i, 20, UInt32.self)), oid: Int(field(i, 24, UInt32.self)),
            title: string(i, 0), artist: string(i, 1), date: string(i, 2),
            kind: kinds[kind(at: i)],
            palette: names(palette, in: palettes),
            nude: isNude(at: i) ? true : nil,
            medium: optional(string(i, 3)), bio: optional(string(i, 4)),
            movements: names(movement, in: movements))
    }

    // MARK: Reading

    private func field<T>(_ i: Int, _ offset: Int, _ type: T.Type) -> T {
        data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: recordsStart + i * Self.recordSize + offset, as: T.self) }
    }

    /// The `n`th string of record `i`: title, artist, date, medium, bio.
    private func string(_ i: Int, _ n: Int) -> String {
        let start = Int(UInt32(littleEndian: field(i, 34 + n * 6, UInt32.self)))
        let length = Int(UInt16(littleEndian: field(i, 38 + n * 6, UInt16.self)))
        let from = data.startIndex + stringsStart + start
        return String(decoding: data[from..<(from + length)], as: UTF8.self)
    }

    private func optional(_ text: String) -> String? { text.isEmpty ? nil : text }

    private func names(_ mask: UInt16, in table: [String]) -> [String]? {
        let picked = table.indices.filter { mask & (1 << UInt16($0)) != 0 }.map { table[$0] }
        return picked.isEmpty ? nil : picked
    }
}
