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
    /// The screen being swiped, in `NSScreen.screens` order.
    private var screenIndex = 0

    /// A two-finger scroll that started over the desktop but hasn't yet
    /// shown whether it's horizontal.
    private var pendingScroll: (dx: CGFloat, dy: CGFloat)?

    private static let commitFraction: CGFloat = 0.22
    private static let commitVelocity: CGFloat = 700  // points per second

    init(controller: WallpaperController) {
        self.controller = controller
    }

    func start() {
        controller.$swipeEnabled.combineLatest(controller.$isOn)
            .map { $0 && $1 }
            .removeDuplicates()
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
            if phase == .tracking { end() }
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
        if towardNext && velocity <= Self.commitVelocity {
            commit(forward: true)
        } else if towardPrevious && velocity >= -Self.commitVelocity && canGoBack {
            commit(forward: false)
        } else {
            cancel()
        }
    }


    /// Without earlier artwork, dragging right stretches instead of revealing.
    private var displayedFraction: CGFloat {
        let fraction = offset / width
        guard fraction > 0, !canGoBack else { return fraction }
        return fraction * 0.25
    }

    private func commit(forward: Bool) {
        phase = .settling
        changeLanded = false
        layoutStages(fraction: forward ? -1 : 1, animated: true)
        let stages = stages
        let done: () -> Void = { [weak self] in
            self?.changeLanded = true
            // Let the real wallpaper settle underneath before revealing it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self?.hideStages(stages) }
        }
        // Start the change straight away; the slide covers the download.
        if forward {
            controller.next(screen: screenIndex, then: done)
        } else {
            controller.previous(screen: screenIndex, then: done)
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
        removeStages()
        let screens = NSScreen.screens
        let current = controller.currentFiles
        // Each display has its own art in per-display mode, so only the
        // swiped one moves; otherwise they all move together.
        let moving = controller.perDisplay ? [screenIndex] : Array(screens.indices)
        stages = moving.filter { current.indices.contains($0) && screens.indices.contains($0) }.map { index in
            let stage = Stage(screen: screens[index], index: index)
            stage.load(current[index], into: stage.current, visibleWhenReady: true)
            return stage
        }
        let newStages = stages
        let screen = screenIndex
        for forward in [true, false] where forward || canGoBack {
            Task { [weak self] in
                guard let files = await self?.controller.neighborFiles(forward: forward, screen: screen) else { return }
                for stage in newStages where files.indices.contains(stage.index) {
                    guard let file = files[stage.index] else { continue }
                    stage.load(file, into: forward ? stage.next : stage.previous, visibleWhenReady: false)
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
            context.duration = 0.25
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
        if wasCurrent, phase == .settling { phase = .idle }
    }

    private func removeStages() {
        stages.forEach { $0.close() }
        stages = []
        if phase == .settling { phase = .idle }
    }

    /// Decode nothing yet, but make sure the next artwork is downloading
    /// as soon as a swipe might start.
    private func warmUp() {
        let screen = Desktop.screenUnderPointer().flatMap { NSScreen.screens.firstIndex(of: $0) }
        Task { _ = await controller.neighborFiles(forward: true, screen: screen) }
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
    private let pixelSize: CGSize
    /// The screen's place in `NSScreen.screens`.
    let index: Int

    init(screen: NSScreen, index: Int) {
        self.index = index
        pixelSize = CGSize(width: screen.frame.width * screen.backingScaleFactor,
                           height: screen.frame.height * screen.backingScaleFactor)
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = NSWindow.Level(Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hasShadow = false
        backgroundColor = .black
        alphaValue = 0  // until the current artwork is decoded, so it never flashes black

        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        contentView = view

        let size = screen.frame.size
        let scale = screen.backingScaleFactor
        strip.frame = CGRect(origin: .zero, size: size)
        for (layer, slot) in [(previous, -1), (current, 0), (next, 1)] {
            // Same fill-and-crop as the wallpaper, so the hand-off is invisible.
            layer.contentsGravity = .resizeAspectFill
            layer.masksToBounds = true
            layer.contentsScale = scale
            layer.backgroundColor = NSColor(white: 0.08, alpha: 1).cgColor
            layer.frame = CGRect(x: CGFloat(slot) * (size.width + DesktopSwiperGap.value), y: 0,
                                 width: size.width, height: size.height)
            strip.addSublayer(layer)
        }
        view.layer?.addSublayer(strip)
        setFrame(screen.frame, display: false)
        orderFrontRegardless()
    }

    /// Moves the strip so `fraction` of a screen width has slid past; -1
    /// shows the next artwork, 1 the previous.
    func slide(to fraction: CGFloat, animated: Bool) {
        let x = fraction * (frame.width + DesktopSwiperGap.value)
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
    func load(_ file: URL, into layer: CALayer, visibleWhenReady: Bool, then: (() -> Void)? = nil) {
        let size = pixelSize
        Task.detached(priority: .userInitiated) {
            let image = Self.decode(file, covering: size)
            await MainActor.run {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.contents = image
                CATransaction.commit()
                if visibleWhenReady { self.alphaValue = 1 }
                then?()
            }
        }
    }

    /// The image scaled down just enough to still fill `size` when cropped.
    nonisolated private static func decode(_ file: URL, covering size: CGSize) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = props[kCGImagePropertyPixelHeight] as? CGFloat,
              width > 0, height > 0
        else { return nil }
        let fill = max(size.width / width, size.height / height)
        let longest = max(width, height) * min(fill, 1)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(longest.rounded(.up)),
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

// MARK: - Crossfade

/// Changes the wallpaper without a hard cut: each screen is covered with a
/// picture of what it shows now, the wallpaper is changed underneath, and
/// the cover slowly fades away.
@MainActor
enum Crossfade {
    /// `covering` is what each screen shows now, in `NSScreen.screens`
    /// order. `change` makes the switch and calls its argument when done.
    static func run(covering files: [URL?], change: @escaping (@escaping () -> Void) -> Void) {
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
            change {
                // Let the new wallpaper land underneath, then reveal it.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    NSAnimationContext.runAnimationGroup({ context in
                        context.duration = 0.9
                        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                        stages.forEach { $0.0.animator().alphaValue = 0 }
                    }, completionHandler: {
                        stages.forEach { $0.0.close() }
                    })
                }
            }
        }
        guard !stages.isEmpty else { start(); return }
        for (stage, file) in stages {
            stage.load(file, into: stage.current, visibleWhenReady: true) {
                waiting -= 1
                if waiting == 0 { start() }
            }
        }
        // Don't hold the switch up if an image won't decode.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { start() }
    }
}

private enum DesktopSwiperGap {
    static let value: CGFloat = 24
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
        let me = ProcessInfo.processInfo.processIdentifier
        let iconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
        // The Dock, Screenshot and similar system overlays cover whole screens
        // at this level and above, but let clicks through; app windows sit below.
        let overlayLevel = Int(CGWindowLevelForKey(.dockWindow))
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        for window in windows {  // front to back
            guard (window[kCGWindowOwnerPID as String] as? pid_t) != me,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
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
