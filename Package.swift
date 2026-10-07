// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OpenGallery",
    // macOS 13 is the oldest release with MenuBarExtra and SMAppService,
    // and keeps the app installable on Intel Macs.
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "OpenGallery", path: "Sources/OpenGallery")
    ]
)
