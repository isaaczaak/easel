import AppKit
import Combine
import ImageIO
import QuartzCore

/// Lets you slide the wallpaper sideways to change artwork with a
/// two-finger swipe on the empty desktop, like swiping between pages.
///
/// Finder owns the desktop, so the swipe is read from a global scroll
/// monitor, and the sliding artwork is drawn in a *stage* window per screen,
/// just above the wallpaper and below the icons. A stage ignores the mouse
/// and only exists during a swipe; afterwards the real wallpaper is set and
/// it fades away.
@MainActor
final class DesktopSwiper {
    private let controller: WallpaperController
    private var stages: [Stage] = []
    private var scrollMonitor: Any?
    private var observers: [AnyCancellable] = []

    private enum Phase { case idle, tracking, settling }
    private var phase = Phase.idle
    /// The last change has reached the real wallpaper; only the fade-out
    /// remains, so a new swipe can cut it short.
    private var changeLanded = false
    /// Horizontal travel in points on `width`, positive when dragged right.
    private var offset: CGFloat = 0
    private var width: CGFloat = 1
    private var samples: [(time: TimeInterval, offset: CGFloat)] = []
    private var canGoBack = false
    private var canGoForward = true
    /// The screen being swiped, in `NSScreen.screens` order.
    private var screenIndex = 0

    /// Images decoded as soon as fingers land, so a swipe shows from its
    /// first frame; one decode per file, shared by whoever needs it. Held
    /// only during a gesture, then released.
    private var decodes: [URL: Task<CGImage?, Never>] = [:]
    private var readying: Task<Void, Never>?

    /// A two-finger scroll that started over the desktop but hasn't yet
    /// shown whether it's horizontal.
    private var pendingScroll: (dx: CGFloat, dy: CGFloat)?

    private static let commitFraction: CGFloat = 0.22
    private static let commitVelocity: CGFloat = 700  // points per second

    init(controller: WallpaperController) {
        self.controller = controller
    }

    func start() {
        controller.whileOn(controller.$swipeEnabled)
            .sink { [weak self] enabled in self?.setEnabled(enabled) }
            .store(in: &observers)
    }

    private func setEnabled(_ enabled: Bool) {
        if enabled {
            // Global monitors see events going to other apps (here, Finder's
            // desktop); scroll events need no Accessibility permission.
            scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                MainActor.assumeIsolated { self?.handleScroll(event) }
            }
        } else {
            if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
            scrollMonitor = nil
        }
    }

    // MARK: - Trackpad

    private func handleScroll(_ event: NSEvent) {
        // Momentum after the fingers lift belongs to whatever ran before.
        guard event.momentumPhase.isEmpty, event.hasPreciseScrollingDeltas else { return }
        // Follow the fingers whichever way scrolling is set to go.
        let dx = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
        let dy = event.scrollingDeltaY

        switch event.phase {
        case .began:
            pendingScroll = isReady && Desktop.isUnderPointer() ? (0, 0) : nil
            if pendingScroll != nil { warmUp() }
        case .changed:
            if phase == .tracking, pendingScroll == nil {
                move(by: dx)
            } else if var pending = pendingScroll {
                pending.dx += dx
                pending.dy += abs(dy)
                if abs(pending.dy) > 10 {
                    pendingScroll = nil  // vertical: not ours
                } else if abs(pending.dx) > 10, abs(pending.dx) > pending.dy * 1.5,
                          let screen = Desktop.screenUnderPointer() {
                    pendingScroll = nil
                    begin(on: screen)
                    move(by: pending.dx)
                } else {
                    pendingScroll = pending
                }
            }
        case .ended, .cancelled:
            pendingScroll = nil
            if phase == .tracking { end() } else if phase == .idle { releaseReady() }
        default:
            break
        }
    }

    // MARK: - Gesture

    private var isReady: Bool { phase == .idle || phase == .settling && changeLanded }

    private func begin(on screen: NSScreen) {
        guard isReady, !controller.currentFiles.isEmpty else { return }
        phase = .tracking
        offset = 0
        width = screen.frame.width
        samples = [(ProcessInfo.processInfo.systemUptime, 0)]
        screenIndex = NSScreen.screens.firstIndex(of: screen) ?? 0
        canGoBack = controller.canGoBack(screen: screenIndex)
        canGoForward = controller.canGoForward(screen: screenIndex)
        showStages()
    }

    private func move(by dx: CGFloat) {
        guard phase == .tracking else { return }
        offset += dx
        let now = ProcessInfo.processInfo.systemUptime
        samples.append((now, offset))
        samples.removeAll { now - $0.time > 0.1 }
        layoutStages(fraction: displayedFraction, animated: false)
    }

    private func end() {
        guard phase == .tracking else { return }
        let fraction = offset / width
        var velocity: CGFloat = 0
        if let first = samples.first, let last = samples.last, last.time - first.time > 0.01 {
            velocity = (last.offset - first.offset) / CGFloat(last.time - first.time)
        }
        let towardNext = fraction < -Self.commitFraction || velocity < -Self.commitVelocity
        let towardPrevious = fraction > Self.commitFraction || velocity > Self.commitVelocity
        if towardNext && velocity <= Self.commitVelocity && canGoForward {
            commit(forward: true)
        } else if towardPrevious && velocity >= -Self.commitVelocity && canGoBack {
            commit(forward: false)
        } else {
            cancel()
        }
    }

    /// Without earlier artwork, dragging right stretches instead of revealing.
    /// With nothing that way, or the artwork there still loading, dragging
    /// stretches instead of revealing an empty panel.
    private var displayedFraction: CGFloat {
        let fraction = offset / width
        if fraction > 0 && !(canGoBack && incomingReady(forward: false))
            || fraction < 0 && !(canGoForward && incomingReady(forward: true)) {
            return fraction * 0.25
        }
        return fraction
    }

    private func incomingReady(forward: Bool) -> Bool {
        !stages.isEmpty && stages.allSatisfy { (forward ? $0.next : $0.previous).contents != nil }
    }

    private func commit(forward: Bool) {
        phase = .settling
        changeLanded = false
        slideWhenReady(to: forward ? -1 : 1, forward: forward)
        let stages = stages
        let done: () -> Void = { [weak self] in
            self?.changeLanded = true
            // macOS takes up to about two seconds to show a new wallpaper; keep
            // the slide's last frame up until then, so the old artwork never
            // shows through. A new swipe can still start meanwhile.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { self?.hideStages(stages) }
        }
        // Start the change straight away; the slide covers the download.
        if forward {
            controller.next(screen: screenIndex, then: done)
        } else {
            controller.previous(screen: screenIndex, then: done)
        }
    }

    /// Slides once the incoming artwork is ready, so a release never slides
    /// in an empty panel. If it's still downloading, the swipe holds where
    /// it was let go with a spinner. Stops once the overlay is gone (it
    /// leaves a few seconds after the change, even if that failed).
    private func slideWhenReady(to fraction: CGFloat, forward: Bool, waited: TimeInterval = 0) {
        let current = stages
        guard !current.isEmpty, phase == .settling else { return }
        let ready = current.allSatisfy { (forward ? $0.next : $0.previous).contents != nil }
        if ready {
            current.forEach { $0.showSpinner(false) }
            layoutStages(fraction: fraction, animated: true)
            return
        }
        if waited >= 0.25 { current.forEach { $0.showSpinner(true) } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.stages == current else { return }
            self.slideWhenReady(to: fraction, forward: forward, waited: waited + 0.05)
        }
    }

    private func cancel() {
        phase = .settling
        changeLanded = true
        layoutStages(fraction: 0, animated: true)
        let stages = stages
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.closeStages(stages)
        }
    }

    // MARK: - Stages

    private func showStages() {
        // The previous swipe's overlay may still be covering a wallpaper
        // macOS hasn't finished switching; close it only once the new one
        // is showing, so nothing behind it flashes through.
        let previous = stages
        var waiting = 0
        let closePrevious = { [weak self] in
            waiting -= 1
            guard waiting <= 0 else { return }
            previous.forEach { $0.close() }
            self?.stages.removeAll { previous.contains($0) }
        }
        let screens = NSScreen.screens
        let current = controller.currentFiles
        // Each display has its own art in per-display mode, so only the
        // swiped one moves; otherwise they all move together.
        let moving = controller.perDisplay ? [screenIndex] : Array(screens.indices)
        stages = moving.filter { current.indices.contains($0) && screens.indices.contains($0) }.map { index in
            let stage = Stage(screen: screens[index], index: index)
            waiting += 1
            loadOnce(current[index], into: stage, layer: stage.current, visibleWhenReady: true, then: closePrevious)
            return stage
        }
        if waiting == 0 { closePrevious() }
        let newStages = stages
        let screen = screenIndex
        for forward in [true, false] where forward ? canGoForward : canGoBack {
            Task { [weak self] in
                guard let files = await self?.controller.neighborFiles(forward: forward, screen: screen) else { return }
                for stage in newStages where files.indices.contains(stage.index) {
                    guard let file = files[stage.index] else { continue }
                    self?.loadOnce(file, into: stage, layer: forward ? stage.next : stage.previous,
                                   visibleWhenReady: false) {
                        // Arrived mid-drag: catch up with the fingers.
                        guard let self, self.phase == .tracking else { return }
                        self.layoutStages(fraction: self.displayedFraction, animated: true)
                    }
                }
            }
        }
        layoutStages(fraction: 0, animated: false)
    }

    private func layoutStages(fraction: CGFloat, animated: Bool) {
        for stage in stages {
            stage.slide(to: fraction, animated: animated)
        }
    }

    private func hideStages(_ stages: [Stage]) {
        let stages = stages.filter { self.stages.contains($0) }  // not already replaced by a newer swipe
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.4
            stages.forEach { $0.animator().alphaValue = 0 }
        }, completionHandler: { [weak self] in
            Task { @MainActor in self?.closeStages(stages) }
        })
    }

    /// Closes `stages` unless a newer swipe already replaced them.
    private func closeStages(_ old: [Stage]) {
        old.forEach { $0.close() }
        let wasCurrent = !old.isEmpty && old.allSatisfy { stages.contains($0) }
        stages.removeAll { old.contains($0) }
        if wasCurrent, phase == .settling {
            phase = .idle
            releaseReady()
        }
    }

    /// Shows `file` on `stage` with the shared decode, so the same image is
    /// never decoded twice.
    private func loadOnce(_ file: URL, into stage: Stage, layer: CALayer, visibleWhenReady: Bool,
                          then: (() -> Void)? = nil) {
        let decoding = decode(file, size: stage.pixelSize, space: stage.screenSpace)
        Task {
            let image = await decoding.value
            stage.load(file, into: layer, visibleWhenReady: visibleWhenReady, ready: image, then: then)
        }
    }

    private func releaseReady() {
        readying?.cancel()
        readying = nil
        decodes = [:]
        Memory.relieve()
    }


    /// Fingers just landed on the desktop: decode the images a swipe would
    /// show, so it can start on its first frame.
    private func warmUp() {
        let screens = NSScreen.screens
        guard let pointer = Desktop.screenUnderPointer(), let screen = screens.firstIndex(of: pointer) else { return }
        let moving = controller.perDisplay ? [screen] : Array(screens.indices)
        let current = controller.currentFiles
        for i in moving where current.indices.contains(i) {
            _ = decode(current[i], size: screens[i].pixelSize, space: Stage.colorSpace(of: screens[i]))
        }
        readying?.cancel()
        readying = Task { [weak self] in
            for forward in [true, false] {
                guard let neighbors = await self?.controller.neighborFiles(forward: forward, screen: screen),
                      !Task.isCancelled
                else { continue }
                for i in moving where neighbors.indices.contains(i) {
                    if let file = neighbors[i] {
                        _ = self?.decode(file, size: screens[i].pixelSize, space: Stage.colorSpace(of: screens[i]))
                    }
                }
            }
        }
    }

    /// The decode of `file`, started if it isn't already running.
    private func decode(_ file: URL, size: CGSize, space: CGColorSpace) -> Task<CGImage?, Never> {
        if let running = decodes[file] { return running }
        let task = Task.detached(priority: .userInitiated) { Stage.decode(file, covering: size, in: space) }
        decodes[file] = task
        return task
    }
}

// MARK: - Stage window

/// Full-screen, click-through window between the wallpaper and the icons
/// showing the previous, current and next artwork side by side.
@MainActor
private final class Stage: NSWindow {
    let previous = CALayer()
    let current = CALayer()
    let next = CALayer()
    private let strip = CALayer()
    let pixelSize: CGSize
    let screenSpace: CGColorSpace
    /// Never fully opaque: if the desktop is completely covered, macOS pauses
    /// the wallpaper, and uncovering it shows black until it restarts. 1%
    /// see-through is invisible.
    static let shownAlpha: CGFloat = 0.99
    /// The screen's place in `NSScreen.screens`.
    let index: Int
    /// Space between neighbouring artworks while they slide.
    private static let gap: CGFloat = 24

    init(screen: NSScreen, index: Int) {
        self.index = index
        pixelSize = screen.pixelSize
        screenSpace = Self.colorSpace(of: screen)
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = NSWindow.Level(Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hasShadow = false
        // Not opaque, so macOS keeps drawing the desktop underneath: it stops
        // rendering a fully covered wallpaper, and uncovering it would show
        // black (or the old artwork) until it caught up.
        isOpaque = false
        backgroundColor = .clear
        alphaValue = 0  // until the current artwork is decoded, so it never flashes black

        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        contentView = view

        let size = screen.frame.size
        strip.frame = CGRect(origin: .zero, size: size)
        for (layer, slot) in [(previous, -1), (current, 0), (next, 1)] {
            // Same fill-and-crop as the wallpaper, so the hand-off is invisible.
            layer.contentsGravity = .resizeAspectFill
            layer.masksToBounds = true
            layer.contentsScale = screen.backingScaleFactor
            // While an artwork loads, its panel shows the gallery wall's plaster.
            layer.backgroundColor = CGColor(srgbRed: 0.91, green: 0.88, blue: 0.83, alpha: 1)
            layer.frame = CGRect(x: CGFloat(slot) * (size.width + Self.gap), y: 0,
                                 width: size.width, height: size.height)
            strip.addSublayer(layer)
        }
        view.layer?.addSublayer(strip)
        setFrame(screen.frame, display: false)
        orderFrontRegardless()
    }

    /// Drops the images before closing: Core Animation can keep a closed
    /// window's layers, and their pixels, alive long after.
    override func close() {
        orderOut(nil)  // off screen first, or the black backing shows for a frame
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [previous, current, next] {
            layer.removeAllAnimations()
            layer.contents = nil
        }
        strip.removeAllAnimations()
        CATransaction.commit()
        super.close()
    }

    private var spinner: NSProgressIndicator?

    /// A spinner in the middle of the screen, for an artwork still downloading.
    func showSpinner(_ show: Bool) {
        if show, spinner == nil, let view = contentView {
            let indicator = NSProgressIndicator()
            indicator.style = .spinning
            indicator.controlSize = .large
            indicator.appearance = NSAppearance(named: .darkAqua)
            indicator.sizeToFit()
            indicator.frame.origin = NSPoint(x: view.bounds.midX - indicator.frame.width / 2,
                                             y: view.bounds.midY - indicator.frame.height / 2)
            view.addSubview(indicator)
            indicator.startAnimation(nil)
            spinner = indicator
        } else if !show, let indicator = spinner {
            indicator.stopAnimation(nil)
            indicator.removeFromSuperview()
            spinner = nil
        }
    }

    /// Moves the strip so `fraction` of a screen width has slid past; -1
    /// shows the next artwork, 1 the previous.
    func slide(to fraction: CGFloat, animated: Bool) {
        let x = fraction * (frame.width + Self.gap)
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.32)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1))
        } else {
            CATransaction.setDisableActions(true)
        }
        strip.setAffineTransform(CGAffineTransform(translationX: x, y: 0))
        CATransaction.commit()
    }

    /// Decodes `file` off the main thread at screen size and shows it.
    func load(_ file: URL, into layer: CALayer, visibleWhenReady: Bool, ready: CGImage? = nil,
              then: (() -> Void)? = nil) {
        if let ready {  // decoded while the fingers settled on the trackpad
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.contents = ready
            CATransaction.commit()
            if visibleWhenReady { alphaValue = Self.shownAlpha }
            then?()
            return
        }
        let size = pixelSize, space = screenSpace
        Task.detached(priority: .userInitiated) {
            let image = Self.decode(file, covering: size, in: space)
            await MainActor.run {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.contents = image
                CATransaction.commit()
                if visibleWhenReady { self.alphaValue = Self.shownAlpha }
                then?()
            }
        }
    }

    static func colorSpace(of screen: NSScreen) -> CGColorSpace {
        screen.colorSpace?.cgColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
    }

    /// The image scaled down just enough to still fill `size` when cropped,
    /// drawn into the screen's own color space. Paintings carry their own
    /// color profiles; left as they are, Core Graphics converts them for
    /// display and keeps every converted copy in a cache that only empties
    /// under memory pressure.
    nonisolated static func decode(_ file: URL, covering size: CGSize, in space: CGColorSpace) -> CGImage? {
        autoreleasepool {
            let noCache = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithURL(file as CFURL, noCache),
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, noCache) as? [CFString: Any],
                  let width = props[kCGImagePropertyPixelWidth] as? CGFloat,
                  let height = props[kCGImagePropertyPixelHeight] as? CGFloat,
                  width > 0, height > 0
            else { return nil }
            let fill = min(max(size.width / width, size.height / height), 1)
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: Int((max(width, height) * fill).rounded(.up)),
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCache: false,
            ]
            guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
                  let ctx = CGContext(data: nil, width: decoded.width, height: decoded.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return nil }
            ctx.draw(decoded, in: CGRect(x: 0, y: 0, width: decoded.width, height: decoded.height))
            return ctx.makeImage()
        }
    }
}

// MARK: - Crossfade

/// Changes the wallpaper without a hard cut: the new picture fades in over
/// the old straight away, the real wallpaper changes underneath, and the
/// overlay goes once macOS has caught up (about two seconds), when the two
/// look the same.
@MainActor
enum Crossfade {
    /// `files` is the new picture for each screen, in `NSScreen.screens`
    /// order; `change` sets the real wallpaper.
    static func run(to files: [URL?], change: @escaping () -> Void) {
        let screens = NSScreen.screens
        let stages = zip(screens.indices, screens).compactMap { index, screen -> (Stage, URL)? in
            guard files.indices.contains(index), let file = files[index] else { return nil }
            return (Stage(screen: screen, index: index), file)
        }
        var started = false
        var waiting = stages.count
        let start = {
            guard !started else { return }
            started = true
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.6
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                stages.forEach { $0.0.animator().alphaValue = Stage.shownAlpha }
            }
            change()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.6) {
                stages.forEach { $0.0.close() }
                Memory.relieve()
            }
        }
        guard !stages.isEmpty else { start(); return }
        for (stage, file) in stages {
            stage.load(file, into: stage.current, visibleWhenReady: false) {
                waiting -= 1
                if waiting == 0 { start() }
            }
        }
        // Don't hold up the switch if an image won't decode.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { start() }
    }
}

/// Where the pointer is, relative to the desktop.
@MainActor
enum Desktop {
    /// True when the topmost window under the pointer is the desktop itself
    /// (the wallpaper or Finder's icon layer), not an app window.
    static func isUnderPointer() -> Bool {
        guard let primary = NSScreen.screens.first else { return false }
        let mouse = NSEvent.mouseLocation
        // Not over the menu bar or the Dock.
        guard let screen = screenUnderPointer(), NSMouseInRect(mouse, screen.visibleFrame, false) else { return false }
        let point = CGPoint(x: mouse.x, y: primary.frame.maxY - mouse.y)  // window list is top-left based
        let iconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
        // The Dock, Screenshot and similar system overlays cover whole screens
        // at this level and above, but let clicks through; app windows sit below.
        let overlayLevel = Int(CGWindowLevelForKey(.dockWindow))
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        for window in windows {  // front to back
            // OpenGallery's own windows count too: Settings and the details
            // card block swipes, while the swipe overlay sits at desktop level.
            guard (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.contains(point)
            else { continue }
            let layer = window[kCGWindowLayer as String] as? Int ?? 0
            if layer >= overlayLevel { continue }
            return layer <= iconLevel
        }
        return true
    }

    static func screenUnderPointer() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
    }
}
