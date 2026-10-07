// Compresses a file with LZMA, the format the app decompresses at launch.
//   swift scripts/compress.swift <input> <output>
import Foundation

let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let data = try NSData(contentsOf: input).compressed(using: .lzma) as Data
// Verify the round trip before shipping it.
guard try (data as NSData).decompressed(using: .lzma) as Data == Data(contentsOf: input) else {
    fatalError("compressed manifest doesn't round-trip")
}
try data.write(to: output)
