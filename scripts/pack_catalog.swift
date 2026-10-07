// Packs Resources/manifest.json into the compact, LZMA-compressed catalog the
// app loads (see Catalog.swift for the format). Run by scripts/bundle.sh.
//   swift scripts/pack_catalog.swift <manifest.json> <catalog.bin.lzma>
import Foundation

let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: input)) as! [String: Any]
let artworks = manifest["artworks"] as! [[String: Any]]

func names(_ key: String) -> [String] {
    var seen = Set<String>()
    for artwork in artworks {
        if let one = artwork[key] as? String { seen.insert(one) }
        for many in artwork[key] as? [String] ?? [] { seen.insert(many) }
    }
    return seen.sorted()
}
let kinds = names("kind"), palettes = names("palette"), movements = names("movements")
precondition(kinds.count <= 255 && palettes.count <= 16 && movements.count <= 16, "too many tags for the format")

var data = Data("OGC1".utf8)
func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
func appendTable(_ table: [String]) {
    append(UInt8(table.count))
    for name in table { append(UInt8(name.utf8.count)); data.append(contentsOf: name.utf8) }
}
func mask(_ values: [String]?, in table: [String]) -> UInt16 {
    (values ?? []).reduce(0) { $0 | (1 << UInt16(table.firstIndex(of: $1)!)) }
}

var strings = Data()
var records = Data()
func appendString(_ text: String?) {
    let bytes = Data((text ?? "").utf8)
    precondition(bytes.count <= Int(UInt16.max))
    withUnsafeBytes(of: UInt32(strings.count).littleEndian) { records.append(contentsOf: $0) }
    withUnsafeBytes(of: UInt16(bytes.count).littleEndian) { records.append(contentsOf: $0) }
    strings.append(bytes)
}
func appendRecord<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { records.append(contentsOf: $0) } }

var count = 0
for artwork in artworks {
    guard let uuid = UUID(uuidString: artwork["id"] as! String) else { continue }  // ids become file names
    withUnsafeBytes(of: uuid.uuid) { records.append(contentsOf: $0) }
    appendRecord(UInt32(artwork["w"] as! Int))
    appendRecord(UInt32(artwork["h"] as! Int))
    appendRecord(UInt32(artwork["oid"] as! Int))
    appendRecord(UInt8(kinds.firstIndex(of: artwork["kind"] as! String)!))
    appendRecord(UInt8((artwork["nude"] as? Bool) == true ? 1 : 0))
    appendRecord(mask(artwork["palette"] as? [String], in: palettes))
    appendRecord(mask(artwork["movements"] as? [String], in: movements))
    for key in ["title", "artist", "date", "medium", "bio"] { appendString(artwork[key] as? String) }
    count += 1
}

append(UInt32(count))
appendTable(kinds)
appendTable(palettes)
appendTable(movements)
append(UInt32(strings.count))
data.append(records)
data.append(strings)

let compressed = try (data as NSData).compressed(using: .lzma) as Data
guard try (compressed as NSData).decompressed(using: .lzma) as Data == data else {
    fatalError("catalog doesn't round-trip")
}
try compressed.write(to: output)
print("packed \(count) artworks: \(data.count / 1024) KB, \(compressed.count / 1024) KB compressed")
