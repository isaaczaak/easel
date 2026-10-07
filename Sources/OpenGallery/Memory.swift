import Darwin

enum Memory {
    /// Returns freed memory to macOS. After large temporary images are
    /// released, the allocator otherwise keeps their pages, and Activity
    /// Monitor counts them against the app.
    static func relieve() {
        malloc_zone_pressure_relief(nil, 0)
    }
}
