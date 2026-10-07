import AppKit
import Combine
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
///
/// History is kept as *tracks*: one in single mode, shared by every screen,
/// or one per screen (in `NSScreen.screens` order) in per-display mode, so
/// each screen can go back and forth on its own.
@MainActor
final class WallpaperController: ObservableObject {
    @Published private(set) var current: [Showing] = []
    @Published private(set) var status: String?
    /// Favorite artwork ids, newest first.
    @Published private(set) var favorites: [String]
    @Published private(set) var launchAtLogin = false
    /// The file on each screen, in `NSScreen.screens` order.
    @Published private(set) var currentFiles: [URL] = []

    @Published var interval: RotationInterval {
        didSet { defaults.set(interval.rawValue, forKey: Keys.interval) }
    }
    @Published var enabledKinds: Set<String> {
        didSet { defaults.set(Array(enabledKinds), forKey: Keys.kinds); upNext = [:] }
    }
    /// Selected palette colors; empty means any color.
    @Published var palettes: Set<String> {
        didSet { defaults.set(Array(palettes), forKey: Keys.palettes); upNext = [:] }
    }
    @Published var orientation: Orientation {
        didSet { defaults.set(orientation.rawValue, forKey: Keys.orientation); upNext = [:] }
    }
    /// Selected art movements; empty means any (including untagged works).
    @Published var movements: Set<String> {
        didSet { defaults.set(Array(movements), forKey: Keys.movements); upNext = [:] }
    }
    @Published var hideNudity: Bool {
        didSet {
            defaults.set(hideNudity, forKey: Keys.hideNudity)
            upNext = [:]
            // Swap out anything now hidden that's on screen.
            if hideNudity, current.contains(where: { $0.artwork.nude == true }) {
                skipToEnd()
                next()
            }
        }
    }
    @Published var favoritesOnly: Bool {
        didSet { defaults.set(favoritesOnly, forKey: Keys.favoritesOnly); upNext = [:] }
    }
    @Published var perDisplay: Bool {
        didSet {
            defaults.set(perDisplay, forKey: Keys.perDisplay)
            upNext = [:]
            // Single mode carries on the first screen's track.
            if !perDisplay { tracks = Array(tracks.prefix(1)); positions = Array(positions.prefix(1)) }
            skipToEnd()  // always pick fresh art, not forward history
            next()
        }
    }
    @Published var swipeEnabled: Bool {
        didSet { defaults.set(swipeEnabled, forKey: Keys.swipeEnabled) }
    }
    /// Off hands the desktop back: the wallpapers from before OpenGallery return
    /// and nothing changes until it's switched on again.
    @Published var isOn: Bool {
        didSet {
            guard isOn != oldValue else { return }
            defaults.set(isOn, forKey: Keys.isOn)
            if isOn {
                saveSystemWallpapers()
                let showing = NSScreen.screens.map { NSWorkspace.shared.desktopImageURL(for: $0) }
                Crossfade.run(covering: showing) { done in
                    self.currentFiles = []  // so every screen is set again
                    self.showCurrent(then: done)
                }
            } else {
                loadTask?.cancel()
                Crossfade.run(covering: currentFiles) { done in
                    self.restoreSystemWallpapers()
                    done()
                }
            }
        }
    }
    @Published var forceClickEnabled: Bool {
        didSet { defaults.set(forceClickEnabled, forKey: Keys.forceClickEnabled) }
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
        static let palettes = "palettes", hideNudity = "hideNudity", movements = "movements"
        static let orientation = "orientation"
        static let tracks = "tracks", positions = "trackPositions", lastChange = "lastChange"
        static let launchAtLogin = "launchAtLogin", swipeEnabled = "swipeEnabled"
        static let forceClickEnabled = "forceClickEnabled", isOn = "isOn"
        static let systemWallpapers = "systemWallpapers"
    }

    private static let historyLimit = 50
    private static let wallpaperOptions: [NSWorkspace.DesktopImageOptionKey: Any] = [
        .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
        .allowClipping: true,  // fill the screen, cropping edges, instead of letterboxing
    ]

    private let defaults = UserDefaults.standard
    private let catalog: Catalog
    private let cache = ImageCache()

    /// Artwork ids per track, oldest first; `positions[t]` is on screen.
    private var tracks: [[String]]
    private var positions: [Int]
    private var lastChange: Date {
        didSet { defaults.set(lastChange, forKey: Keys.lastChange) }
    }
    /// The next fresh pick for each track, downloaded ahead of time.
    /// The next few fresh picks for each track, downloaded ahead of time so
    /// rotating or swiping never waits on the network.
    private var upNext: [Int: [Artwork]] = [:]
    private static let readyAhead = 3
    private var loadTask: Task<Void, Never>?
    private var timer: Timer?

    /// `setting` combined with the on/off switch: a desktop feature is
    /// active only while both are on.
    func whileOn(_ setting: Published<Bool>.Publisher) -> AnyPublisher<Bool, Never> {
        setting.combineLatest($isOn).map { $0 && $1 }.removeDuplicates().eraseToAnyPublisher()
    }

    /// Whether `previous()` has anywhere to go, on every screen or one.
    func canGoBack(screen: Int? = nil) -> Bool {
        trackIndices(for: screen).contains { positions[$0] > 0 }
    }

    init() {
        let catalog = Catalog.loadBundled()
        self.catalog = catalog

        interval = RotationInterval(rawValue: defaults.integer(forKey: Keys.interval)) ?? .hour
        enabledKinds = Set(defaults.stringArray(forKey: Keys.kinds) ?? [ArtKind.painting.rawValue])
        palettes = Set(defaults.stringArray(forKey: Keys.palettes) ?? [])
        movements = Set(defaults.stringArray(forKey: Keys.movements) ?? [])
        orientation = Orientation(rawValue: defaults.string(forKey: Keys.orientation) ?? "") ?? .any
        hideNudity = defaults.object(forKey: Keys.hideNudity) as? Bool ?? true
        favoritesOnly = defaults.bool(forKey: Keys.favoritesOnly)
        perDisplay = defaults.bool(forKey: Keys.perDisplay)
        paused = defaults.bool(forKey: Keys.paused)
        swipeEnabled = defaults.object(forKey: Keys.swipeEnabled) as? Bool ?? true
        // Off until chosen: it needs Input Monitoring, a sensitive permission.
        forceClickEnabled = defaults.object(forKey: Keys.forceClickEnabled) as? Bool ?? false
        isOn = defaults.object(forKey: Keys.isOn) as? Bool ?? true
        favorites = defaults.stringArray(forKey: Keys.favorites) ?? []

        let tracks = ((defaults.array(forKey: Keys.tracks) as? [[String]]) ?? []).map { $0.filter { catalog.index(of: $0) != nil } }
        let positions = (defaults.array(forKey: Keys.positions) as? [Int]) ?? []
        self.positions = tracks.indices.map { index in
            min(positions.indices.contains(index) ? positions[index] : .max, max(tracks[index].count - 1, 0))
        }
        self.tracks = tracks
        lastChange = defaults.object(forKey: Keys.lastChange) as? Date ?? .distantPast
    }

    func start() {
        restoreLoginItem()
        refreshLoginItemStatus()

        let center = NSWorkspace.shared.notificationCenter
        // setDesktopImageURL only affects the active Space, so re-apply on switch.
        center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // While off, a Space may still show our artwork from before; put
                // its wallpaper back, but leave anything the user chose alone.
                if self.isOn { self.reapply() } else { self.restoreSystemWallpapers(onlyOurs: true) }
            }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // A display was added, removed or changed size.
            Task { @MainActor in
                guard let self, self.isOn else { return }
                self.saveSystemWallpapers()  // a newly connected display's own wallpaper
                self.showCurrent()
            }
        }

        // Check every minute rather than scheduling one long timer, so sleep
        // and interval changes are picked up without rescheduling.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }

        guard isOn else { return }
        saveSystemWallpapers()
        if tracks.allSatisfy(\.isEmpty) || Date().timeIntervalSince(lastChange) >= interval.seconds && !paused {
            next()
        } else {
            showCurrent()
        }
    }

    // MARK: - Navigation

    /// Moves every screen on, or only `screen` in per-display mode. `then`
    /// runs once the new wallpaper is set, or the change failed.
    func next(screen: Int? = nil, retriesLeft: Int = 2, then: (() -> Void)? = nil) {
        guard isOn else { then?(); return }
        ensureTracks()
        let before = positions
        var fresh: Set<Int> = []
        for track in trackIndices(for: screen) {
            if positions[track] < tracks[track].count - 1 {
                positions[track] += 1
                continue
            }
            guard let artwork = takeUpNext(track) else {
                status = "No artworks match your filters"
                then?()
                return
            }
            tracks[track].append(artwork.id)
            if tracks[track].count > Self.historyLimit {
                tracks[track].removeFirst(tracks[track].count - Self.historyLimit)
            }
            positions[track] = tracks[track].count - 1
            fresh.insert(track)
        }
        showCurrent(fresh: fresh, retriesLeft: retriesLeft, restoring: before, then: then)
    }

    func previous(screen: Int? = nil, then: (() -> Void)? = nil) {
        guard isOn else { then?(); return }
        ensureTracks()
        let movable = trackIndices(for: screen).filter { positions[$0] > 0 }
        guard !movable.isEmpty else { then?(); return }
        let before = positions
        for track in movable { positions[track] -= 1 }
        showCurrent(restoring: before, then: then)
    }

    /// Local files for the artwork `next(screen:)` or `previous(screen:)`
    /// would show, one per screen (nil for screens it leaves alone),
    /// downloading them if needed. Nil if there is nothing that way.
    func neighborFiles(forward: Bool, screen: Int? = nil) async -> [URL?]? {
        ensureTracks()
        let moving = Set(trackIndices(for: screen))
        var ids = trackIDs()
        var changed = false
        for track in moving {
            let position = positions[track] + (forward ? 1 : -1)
            if tracks[track].indices.contains(position) {
                ids[track] = tracks[track][position]
                changed = true
            } else if forward {
                prefetch()  // `next()` takes exactly these
                if let artwork = upNext[track]?.first {
                    ids[track] = artwork.id
                    changed = true
                }
            }
        }
        guard changed else { return nil }
        let screens = NSScreen.screens
        guard let files = try? await download(jobs(for: ids, on: screens)) else { return nil }
        return screens.indices.map { index in moving.contains(trackIndex(forScreen: index)) ? files[index] : nil }
    }

    func isFavorite(_ artwork: Artwork) -> Bool {
        favorites.contains(artwork.id)
    }

    static let favoritesLimit = 20

    var favoriteArtworks: [Artwork] { favorites.compactMap(catalog.artwork(id:)) }
    var favoritesFull: Bool { favorites.count >= Self.favoritesLimit }

    /// Adding does nothing once there are `favoritesLimit` favorites.
    func toggleFavorite(_ artwork: Artwork) {
        if let index = favorites.firstIndex(of: artwork.id) {
            favorites.remove(at: index)
        } else if !favoritesFull {
            favorites.insert(artwork.id, at: 0)
        }
        defaults.set(favorites, forKey: Keys.favorites)
        if favoritesOnly { upNext = [:] }
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

    func setMovement(_ movement: ArtMovement, enabled: Bool) {
        if enabled {
            movements.insert(movement.rawValue)
        } else {
            movements.remove(movement.rawValue)  // removing the last one means "Any"
        }
    }

    /// How many artworks of the enabled kinds are tagged with each movement.
    var movementCounts: [String: Int] {
        let kinds = Catalog.mask(enabledKinds, in: catalog.kinds)
        var counts = [Int](repeating: 0, count: catalog.movements.count)
        for i in 0..<catalog.count
        where kinds & (1 << UInt16(catalog.kind(at: i))) != 0 && orientation.includes(fillsScreen: catalog.fillsScreen(at: i)) {
            let mask = catalog.movementMask(at: i)
            for bit in counts.indices where mask & (1 << UInt16(bit)) != 0 { counts[bit] += 1 }
        }
        return Dictionary(uniqueKeysWithValues: zip(catalog.movements, counts))
    }

    func setPalette(_ color: PaletteColor, enabled: Bool) {
        if enabled {
            palettes.insert(color.rawValue)
        } else {
            palettes.remove(color.rawValue)  // removing the last one means "Any"
        }
    }

    // MARK: - Tracks

    private var trackCount: Int { perDisplay ? max(NSScreen.screens.count, 1) : 1 }

    private func trackIndex(forScreen screen: Int) -> Int { perDisplay ? screen : 0 }

    /// The tracks a change on `screen` moves: just its own in per-display
    /// mode, otherwise every track.
    private func trackIndices(for screen: Int?) -> [Int] {
        let all = Array(0..<min(trackCount, tracks.count))
        guard let screen, perDisplay, all.contains(screen) else { return all }
        return [screen]
    }

    /// One track per screen in per-display mode; a newly plugged-in screen
    /// starts with fresh art.
    private func ensureTracks() {
        while tracks.count < trackCount {
            tracks.append([])
            positions.append(0)
        }
        for track in 0..<trackCount where tracks[track].isEmpty {
            let showing = Set(trackIDs().compactMap { $0 })
            if let pick = pickOne(excluding: showing) {
                tracks[track] = [pick.id]
                positions[track] = 0
            }
        }
    }

    /// The id each track is showing, by track.
    private func trackIDs() -> [String?] {
        (0..<min(trackCount, tracks.count)).map { tracks[$0].indices.contains(positions[$0]) ? tracks[$0][positions[$0]] : nil }
    }

    private func skipToEnd() {
        positions = tracks.map { max($0.count - 1, 0) }
    }

    // MARK: - Applying

    private func tick() {
        guard isOn, !paused, Date().timeIntervalSince(lastChange) >= interval.seconds else { return }
        next()
    }

    /// Shows what each track is on. With `retriesLeft > 0`, a failed
    /// download drops the `fresh` picks and tries different artworks instead;
    /// after that, history goes back to `restoring` so it matches the screen.
    private func showCurrent(fresh: Set<Int> = [], retriesLeft: Int = 0, restoring: [Int]? = nil,
                             then: (() -> Void)? = nil) {
        guard isOn else { then?(); return }
        ensureTracks()
        let ids = trackIDs()
        guard ids.allSatisfy({ $0 != nil }), !ids.isEmpty else { then?(); return }
        defaults.set(tracks, forKey: Keys.tracks)
        defaults.set(positions, forKey: Keys.positions)

        let screens = NSScreen.screens
        let jobs = jobs(for: ids, on: screens)

        loadTask?.cancel()
        loadTask = Task {
            do {
                let files = try await download(jobs)
                try Task.checkCancellation()
                for (index, (screen, file)) in zip(screens, files).enumerated()
                    where !currentFiles.indices.contains(index) || currentFiles[index] != file {
                    try NSWorkspace.shared.setDesktopImageURL(file, for: screen, options: Self.wallpaperOptions)
                }
                currentFiles = files
                current = perDisplay
                    ? zip(screens, jobs).enumerated().map { index, pair in
                        Showing(id: index, screenName: Self.label(for: pair.0, among: screens), artwork: pair.1.0)
                    }
                    : jobs.first.map { [Showing(id: 0, screenName: "", artwork: $0.0)] } ?? []
                lastChange = Date()
                status = nil
                prefetch()
                then?()
            } catch {
                // Superseded by a newer load (URLSession throws URLError.cancelled).
                if Task.isCancelled { then?(); return }
                NSLog("OpenGallery: failed to show \(ids): \(error)")
                if retriesLeft > 0, !fresh.isEmpty {
                    for track in fresh {
                        tracks[track].remove(at: positions[track])
                        positions[track] = max(tracks[track].count - 1, 0)
                        upNext[track] = nil
                    }
                    let screen = fresh.count == 1 && perDisplay ? fresh.first : nil
                    if screen == nil, let restoring, restoring.count == positions.count {
                        // The retry moves every track again, so undo the ones that moved.
                        for track in positions.indices where !fresh.contains(track) {
                            positions[track] = restoring[track]
                        }
                    }
                    next(screen: screen, retriesLeft: retriesLeft - 1, then: then)
                } else {
                    for track in fresh where !tracks[track].isEmpty {
                        tracks[track].removeLast()
                    }
                    if let restoring, restoring.count == positions.count {
                        positions = zip(restoring, tracks).map { min($0, max($1.count - 1, 0)) }
                    }
                    defaults.set(tracks, forKey: Keys.tracks)
                    defaults.set(positions, forKey: Keys.positions)
                    status = "Offline — couldn't load artwork"
                    then?()
                }
            }
        }
    }

    /// What to download, one job per screen. Single mode uses one file sized
    /// for the largest screen everywhere.
    private func jobs(for ids: [String?], on screens: [NSScreen]) -> [(Artwork, CGSize)] {
        let largest = Self.largestPixelSize(of: screens)
        return screens.indices.compactMap { index in
            let track = trackIndex(forScreen: index)
            guard ids.indices.contains(track), let id = ids[track], let artwork = catalog.artwork(id: id) else { return nil }
            return (artwork, perDisplay ? screens[index].pixelSize : largest)
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

    // MARK: - System wallpaper

    /// macOS's own default, for displays whose earlier wallpaper wasn't saved.
    private static let defaultWallpaper = URL(fileURLWithPath: "/System/Library/CoreServices/DefaultDesktop.heic")

    private static func displayID(of screen: NSScreen) -> String {
        "\(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] ?? screen.localizedName)"
    }

    /// Whether `url` is artwork OpenGallery downloaded.
    private static func isOurs(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.standardizedFileURL.path.hasPrefix(ImageCache.directory.standardizedFileURL.path + "/")
    }

    /// Remembers each display's wallpaper, unless it's already OpenGallery's.
    private func saveSystemWallpapers() {
        var saved = defaults.dictionary(forKey: Keys.systemWallpapers) as? [String: [String: Any]] ?? [:]
        for screen in NSScreen.screens {
            guard let url = NSWorkspace.shared.desktopImageURL(for: screen), !Self.isOurs(url) else { continue }
            let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
            var entry: [String: Any] = ["path": url.path]
            if let scaling = options[.imageScaling] as? NSNumber { entry["scaling"] = scaling }
            if let clipping = options[.allowClipping] as? NSNumber { entry["clipping"] = clipping }
            saved[Self.displayID(of: screen)] = entry
        }
        defaults.set(saved, forKey: Keys.systemWallpapers)
    }

    /// Puts back each display's saved wallpaper, or macOS's default. With
    /// `onlyOurs`, displays not showing OpenGallery's artwork are left alone.
    private func restoreSystemWallpapers(onlyOurs: Bool = false) {
        let saved = defaults.dictionary(forKey: Keys.systemWallpapers) as? [String: [String: Any]] ?? [:]
        for screen in NSScreen.screens {
            if onlyOurs, !Self.isOurs(NSWorkspace.shared.desktopImageURL(for: screen)) { continue }
            var url = Self.defaultWallpaper
            var options: [NSWorkspace.DesktopImageOptionKey: Any] = [:]
            if let entry = saved[Self.displayID(of: screen)], let path = entry["path"] as? String,
               FileManager.default.fileExists(atPath: path) {
                url = URL(fileURLWithPath: path)
                if let scaling = entry["scaling"] { options[.imageScaling] = scaling }
                if let clipping = entry["clipping"] { options[.allowClipping] = clipping }
            }
            try? NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: options)
        }
    }

    private func reapply() {
        for (screen, file) in zip(NSScreen.screens, currentFiles) {
            try? NSWorkspace.shared.setDesktopImageURL(file, for: screen, options: Self.wallpaperOptions)
        }
    }

    /// Pick and download each track's next artwork ahead of time so
    /// rotation is instant.
    private func prefetch() {
        let screens = NSScreen.screens
        for track in 0..<trackCount {
            var queue = upNext[track] ?? []
            var added: [Artwork] = []
            while queue.count < Self.readyAhead {
                let taken = Set(upNext.values.joined().map(\.id) + queue.map(\.id) + trackIDs().compactMap { $0 })
                guard let pick = pickOne(excluding: taken) else { break }
                queue.append(pick)
                added.append(pick)
            }
            upNext[track] = queue
            guard !added.isEmpty else { continue }
            let size = perDisplay && screens.indices.contains(track)
                ? screens[track].pixelSize : Self.largestPixelSize(of: screens)
            let cache = cache, fetch = added
            Task {  // in order, so the next one is ready first
                for artwork in fetch { _ = try? await cache.file(for: artwork, covering: size) }
            }
        }
    }

    private func takeUpNext(_ track: Int) -> Artwork? {
        if var queue = upNext[track], !queue.isEmpty {
            let next = queue.removeFirst()
            upNext[track] = queue
            return next
        }
        return pickOne(excluding: Set(trackIDs().compactMap { $0 }))
    }

    /// A random artwork matching the filters, other than `excluding`,
    /// avoiding recent ones when the pool is big enough.
    private func pickOne(excluding: Set<String>) -> Artwork? {
        let excluded = Set(excluding.compactMap(catalog.index(of:)))
        let recent = excluded.union(tracks.flatMap { $0.suffix(Self.historyLimit) }.compactMap(catalog.index(of:)))
        let favorite = favoritesOnly ? Set(favorites.compactMap(catalog.index(of:))) : []
        let kinds = Catalog.mask(enabledKinds, in: catalog.kinds)
        let colors = Catalog.mask(palettes, in: catalog.palettes)
        let styles = Catalog.mask(movements, in: catalog.movements)

        // One pass, picking uniformly among matches (reservoir sampling), so
        // no list of candidates is built.
        var fresh: Int?, freshSeen = 0, fallback: Int?, fallbackSeen = 0
        for i in 0..<catalog.count {
            guard kinds & (1 << UInt16(catalog.kind(at: i))) != 0,
                  orientation.includes(fillsScreen: catalog.fillsScreen(at: i)),
                  !favoritesOnly || favorite.contains(i),
                  palettes.isEmpty || catalog.paletteMask(at: i) & colors != 0,
                  movements.isEmpty || catalog.movementMask(at: i) & styles != 0,
                  !(hideNudity && catalog.isNude(at: i)),
                  !excluded.contains(i)
            else { continue }
            fallbackSeen += 1
            if Int.random(in: 0..<fallbackSeen) == 0 { fallback = i }
            if !recent.contains(i) {
                freshSeen += 1
                if Int.random(in: 0..<freshSeen) == 0 { fresh = i }
            }
        }
        return (fresh ?? fallback).map(catalog.artwork(at:))
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

    private static func largestPixelSize(of screens: [NSScreen]) -> CGSize {
        screens.map(\.pixelSize).max { $0.width * $0.height < $1.width * $1.height }
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
            NSLog("OpenGallery: login item change failed: \(error)")
            status = "Couldn't change Launch at Login"
        }
        refreshLoginItemStatus()
    }

    private func refreshLoginItemStatus() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Launch at login defaults to on. Registering again when macOS has lost
    /// the item keeps it working after the app is rebuilt, renamed or moved.
    private func restoreLoginItem() {
        let status = SMAppService.mainApp.status
        if status == .requiresApproval {
            // Switched off in System Settings → Login Items; respect that.
            defaults.set(false, forKey: Keys.launchAtLogin)
            return
        }
        let wanted = defaults.object(forKey: Keys.launchAtLogin) as? Bool ?? true
        if wanted, status == .notRegistered || status == .notFound {
            try? SMAppService.mainApp.register()
        }
    }
}

extension NSScreen {
    /// The screen's size in pixels.
    var pixelSize: CGSize {
        CGSize(width: frame.width * backingScaleFactor, height: frame.height * backingScaleFactor)
    }
}
