import AppKit
import ServiceManagement

enum RotationInterval: Int, CaseIterable, Identifiable {
    case fifteenMinutes = 15
    case hour = 60
    case threeHours = 180
    case day = 1440

    var id: Int { rawValue }
    var seconds: TimeInterval { TimeInterval(rawValue * 60) }
    var label: String {
        switch self {
        case .fifteenMinutes: return "15 Minutes"
        case .hour: return "Hour"
        case .threeHours: return "3 Hours"
        case .day: return "Day"
        }
    }
}

/// One display's current artwork, for the menu.
struct Showing: Identifiable {
    let id: Int  // screen index
    let screenName: String
    let artwork: Artwork
}

/// Picks artworks, downloads them and sets them as the desktop picture,
/// rotating on a timer. Shows one artwork everywhere, or one per display.
@MainActor
final class WallpaperController: ObservableObject {
    @Published private(set) var current: [Showing] = []
    @Published private(set) var status: String?
    @Published private(set) var favorites: Set<String>
    @Published private(set) var launchAtLogin = false

    @Published var interval: RotationInterval {
        didSet { defaults.set(interval.rawValue, forKey: Keys.interval) }
    }
    @Published var enabledKinds: Set<String> {
        didSet { defaults.set(Array(enabledKinds), forKey: Keys.kinds); upNext = [] }
    }
    /// Selected palette colors; empty means any color.
    @Published var palettes: Set<String> {
        didSet { defaults.set(Array(palettes), forKey: Keys.palettes); upNext = [] }
    }
    @Published var favoritesOnly: Bool {
        didSet { defaults.set(favoritesOnly, forKey: Keys.favoritesOnly); upNext = [] }
    }
    @Published var perDisplay: Bool {
        didSet {
            defaults.set(perDisplay, forKey: Keys.perDisplay)
            upNext = []
            position = max(history.count - 1, 0)  // always pick fresh art, not forward history
            next()
        }
    }
    @Published var paused: Bool {
        didSet {
            defaults.set(paused, forKey: Keys.paused)
            if !paused { lastChange = Date() }
        }
    }

    private enum Keys {
        static let interval = "interval", kinds = "kinds", favoritesOnly = "favoritesOnly"
        static let perDisplay = "perDisplay", paused = "paused", favorites = "favorites"
        static let palettes = "palettes"
        static let frames = "frames", position = "position", lastChange = "lastChange"
        static let launchAtLogin = "launchAtLogin"
    }

    private static let historyLimit = 50
    private static let wallpaperOptions: [NSWorkspace.DesktopImageOptionKey: Any] = [
        .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
        .allowClipping: true,  // fill the screen, cropping edges, instead of letterboxing
    ]

    private let defaults = UserDefaults.standard
    private let artworks: [Artwork]
    private let byID: [String: Artwork]
    private let cache = ImageCache()

    /// Each frame is the artwork ids shown together (one, or one per screen
    /// in `NSScreen.screens` order), oldest first; `position` is on screen.
    private var history: [[String]]
    private var position: Int
    private var lastChange: Date {
        didSet { defaults.set(lastChange, forKey: Keys.lastChange) }
    }
    private var upNext: [Artwork] = []
    private var currentFiles: [URL] = []
    private var loadTask: Task<Void, Never>?
    private var timer: Timer?

    var canGoBack: Bool { position > 0 }

    init() {
        let artworks = Manifest.loadBundled().artworks
        let byID = Dictionary(artworks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        self.artworks = artworks
        self.byID = byID

        interval = RotationInterval(rawValue: defaults.integer(forKey: Keys.interval)) ?? .hour
        enabledKinds = Set(defaults.stringArray(forKey: Keys.kinds) ?? [ArtKind.painting.rawValue])
        palettes = Set(defaults.stringArray(forKey: Keys.palettes) ?? [])
        favoritesOnly = defaults.bool(forKey: Keys.favoritesOnly)
        perDisplay = defaults.bool(forKey: Keys.perDisplay)
        paused = defaults.bool(forKey: Keys.paused)
        favorites = Set(defaults.stringArray(forKey: Keys.favorites) ?? [])
        history = ((defaults.array(forKey: Keys.frames) as? [[String]]) ?? [])
            .map { $0.filter { byID[$0] != nil } }
            .filter { !$0.isEmpty }
        position = min(defaults.integer(forKey: Keys.position), max(history.count - 1, 0))
        lastChange = defaults.object(forKey: Keys.lastChange) as? Date ?? .distantPast
    }

    func start() {
        restoreLoginItem()
        refreshLoginItemStatus()

        let center = NSWorkspace.shared.notificationCenter
        // setDesktopImageURL only affects the active Space, so re-apply on switch.
        center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reapply() }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // A display was added, removed or changed size.
            Task { @MainActor in self?.showCurrent() }
        }

        // Check every minute rather than scheduling one long timer, so sleep
        // and interval changes are picked up without rescheduling.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }

        if history.isEmpty || Date().timeIntervalSince(lastChange) >= interval.seconds && !paused {
            next()
        } else {
            showCurrent()
        }
    }

    // MARK: - Navigation

    func next(retriesLeft: Int = 2) {
        if position < history.count - 1 {
            position += 1
            showCurrent()
            return
        }
        let frame = takeUpNext(frameSize)
        guard !frame.isEmpty else {
            status = "No artworks match your filters"
            return
        }
        history.append(frame.map(\.id))
        if history.count > Self.historyLimit {
            history.removeFirst(history.count - Self.historyLimit)
        }
        position = history.count - 1
        showCurrent(retriesLeft: retriesLeft)
    }

    func previous() {
        guard canGoBack else { return }
        position -= 1
        showCurrent()
    }

    func isFavorite(_ artwork: Artwork) -> Bool {
        favorites.contains(artwork.id)
    }

    func toggleFavorite(_ artwork: Artwork) {
        if favorites.contains(artwork.id) {
            favorites.remove(artwork.id)
        } else {
            favorites.insert(artwork.id)
        }
        defaults.set(Array(favorites), forKey: Keys.favorites)
    }

    var showsAllKinds: Bool {
        ArtKind.allCases.allSatisfy { enabledKinds.contains($0.rawValue) }
    }

    func setKind(_ kind: ArtKind, enabled: Bool) {
        if enabled {
            enabledKinds.insert(kind.rawValue)
        } else if enabledKinds.count > 1 {  // keep at least one kind on
            enabledKinds.remove(kind.rawValue)
        }
    }

    /// "All" on enables every kind; off falls back to paintings only.
    func setAllKinds(_ enabled: Bool) {
        enabledKinds = enabled ? Set(ArtKind.allCases.map(\.rawValue)) : [ArtKind.painting.rawValue]
    }

    func setPalette(_ color: PaletteColor, enabled: Bool) {
        if enabled {
            palettes.insert(color.rawValue)
        } else {
            palettes.remove(color.rawValue)  // removing the last one means "Any"
        }
    }

    // MARK: - Applying

    private var frameSize: Int { perDisplay ? max(NSScreen.screens.count, 1) : 1 }

    private func tick() {
        guard !paused, Date().timeIntervalSince(lastChange) >= interval.seconds else { return }
        next()
    }

    /// Shows `history[position]`. With `retriesLeft > 0`, a failed download
    /// drops that frame and tries different artworks instead.
    private func showCurrent(retriesLeft: Int = 0) {
        guard history.indices.contains(position) else { return }
        // A display was plugged in since this frame was picked: give it art too.
        if perDisplay, history[position].count < NSScreen.screens.count {
            let extra = pickRandom(NSScreen.screens.count - history[position].count,
                                   excluding: Set(history[position]))
            history[position] += extra.map(\.id)
        }
        let frame = history[position].compactMap { byID[$0] }
        guard !frame.isEmpty else { return }
        defaults.set(history, forKey: Keys.frames)
        defaults.set(position, forKey: Keys.position)

        let screens = NSScreen.screens
        let largest = Self.largestPixelSize(of: screens)
        // Single mode uses one file sized for the largest screen everywhere.
        let jobs: [(Artwork, CGSize)] = screens.enumerated().map { index, screen in
            perDisplay ? (frame[index % frame.count], Self.pixelSize(of: screen)) : (frame[0], largest)
        }

        loadTask?.cancel()
        loadTask = Task {
            do {
                let files = try await download(jobs)
                try Task.checkCancellation()
                for (screen, file) in zip(screens, files) {
                    try NSWorkspace.shared.setDesktopImageURL(file, for: screen, options: Self.wallpaperOptions)
                }
                currentFiles = files
                current = perDisplay
                    ? zip(screens, jobs).enumerated().map { index, pair in
                        Showing(id: index, screenName: Self.label(for: pair.0, among: screens), artwork: pair.1.0)
                    }
                    : [Showing(id: 0, screenName: "", artwork: frame[0])]
                lastChange = Date()
                status = nil
                prefetch()
            } catch {
                // Superseded by a newer load (URLSession throws URLError.cancelled).
                if Task.isCancelled { return }
                NSLog("Easel: failed to show \(frame.map(\.id)): \(error)")
                if retriesLeft > 0 {
                    history.remove(at: position)
                    position = max(history.count - 1, 0)
                    upNext = []
                    next(retriesLeft: retriesLeft - 1)
                } else {
                    status = "Offline — couldn't load artwork"
                }
            }
        }
    }

    /// Downloads every job in parallel, returning files in job order.
    private func download(_ jobs: [(Artwork, CGSize)]) async throws -> [URL] {
        let cache = cache
        return try await withThrowingTaskGroup(of: (Int, URL).self) { group in
            for (index, job) in jobs.enumerated() {
                group.addTask { (index, try await cache.file(for: job.0, covering: job.1)) }
            }
            var files = [URL?](repeating: nil, count: jobs.count)
            for try await (index, file) in group {
                files[index] = file
            }
            return files.compactMap { $0 }
        }
    }

    private func reapply() {
        for (screen, file) in zip(NSScreen.screens, currentFiles) {
            try? NSWorkspace.shared.setDesktopImageURL(file, for: screen, options: Self.wallpaperOptions)
        }
    }

    /// Download the next frame ahead of time so rotation is instant.
    private func prefetch() {
        guard upNext.isEmpty else { return }
        let screens = NSScreen.screens
        upNext = pickRandom(frameSize, excluding: [])
        let sizes = perDisplay ? screens.map(Self.pixelSize(of:)) : [Self.largestPixelSize(of: screens)]
        for (artwork, size) in zip(upNext, sizes) {
            Task { _ = try? await cache.file(for: artwork, covering: size) }
        }
    }

    private func takeUpNext(_ count: Int) -> [Artwork] {
        let ready = upNext.count == count ? upNext : []
        upNext = []
        return ready.isEmpty ? pickRandom(count, excluding: []) : ready
    }

    /// `count` distinct artworks matching the filters, avoiding recent ones
    /// when the pool is big enough.
    private func pickRandom(_ count: Int, excluding: Set<String>) -> [Artwork] {
        let recent = Set(history.suffix(Self.historyLimit).joined()).union(excluding)
        let pool = artworks.filter {
            enabledKinds.contains($0.kind)
                && (!favoritesOnly || favorites.contains($0.id))
                && (palettes.isEmpty || !palettes.isDisjoint(with: $0.palette ?? []))
        }
        var picks = Array(pool.filter { !recent.contains($0.id) }.shuffled().prefix(count))
        if picks.count < count {
            let chosen = Set(picks.map(\.id)).union(excluding)
            picks += pool.filter { !chosen.contains($0.id) }.shuffled().prefix(count - picks.count)
        }
        return picks
    }

    /// The display's name, shortened for the built-in screen. Identical
    /// monitors get a number so they can be told apart.
    private static func label(for screen: NSScreen, among screens: [NSScreen]) -> String {
        func name(_ screen: NSScreen) -> String {
            screen.localizedName.localizedCaseInsensitiveContains("built-in") ? "Built-in Display" : screen.localizedName
        }
        let twins = screens.filter { name($0) == name(screen) }
        guard twins.count > 1, let index = twins.firstIndex(of: screen) else { return name(screen) }
        return "\(name(screen)) \(index + 1)"
    }

    private static func pixelSize(of screen: NSScreen) -> CGSize {
        CGSize(width: screen.frame.width * screen.backingScaleFactor,
               height: screen.frame.height * screen.backingScaleFactor)
    }

    private static func largestPixelSize(of screens: [NSScreen]) -> CGSize {
        screens.map(pixelSize(of:)).max { $0.width * $0.height < $1.width * $1.height }
            ?? CGSize(width: 2880, height: 1800)
    }

    // MARK: - Launch at login

    func setLaunchAtLogin(_ enabled: Bool) {
        defaults.set(enabled, forKey: Keys.launchAtLogin)
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Easel: login item change failed: \(error)")
            status = "Couldn't change Launch at Login"
        }
        refreshLoginItemStatus()
    }

    private func refreshLoginItemStatus() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Launch at login defaults to on. Re-registering each launch keeps it
    /// working after the app is rebuilt, re-signed, renamed or moved.
    private func restoreLoginItem() {
        let wanted = defaults.object(forKey: Keys.launchAtLogin) as? Bool ?? true
        if wanted, SMAppService.mainApp.status != .enabled {
            try? SMAppService.mainApp.register()
        }
    }
}
