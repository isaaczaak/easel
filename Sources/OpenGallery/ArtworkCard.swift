import AppKit
import Combine
import SwiftUI

/// Force Click on the empty desktop shows a museum-style label for the
/// artwork on that screen. Clicking anywhere else or pressing Esc closes it.
///
/// macOS only shares trackpad pressure with an event tap, and a tap only
/// receives events once the app has the Input Monitoring permission.
@MainActor
final class ArtworkCardPresenter {
    private let controller: WallpaperController
    private var monitors: [Any] = []
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var observers: [AnyCancellable] = []
    private var panel: CardPanel?
    /// Pressure stage of the current press, so one press opens one card.
    private var stage = 0

    init(controller: WallpaperController) {
        self.controller = controller
    }

    func start() {
        controller.whileOn(controller.$forceClickEnabled)
            .sink { [weak self] enabled in self?.setEnabled(enabled) }
            .store(in: &observers)
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .sink { [weak self] _ in self?.close() }
            .store(in: &observers)
    }

    private func setEnabled(_ enabled: Bool) {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        removeTap()
        close()
        guard enabled else { return }
        if CGPreflightListenEventAccess() {
            installTap()
        } else {
            // Adds OpenGallery to Privacy & Security → Input Monitoring and asks
            // once. macOS relaunches the app when it's granted.
            CGRequestListenEventAccess()
        }
        // Any click outside the card closes it.
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }) {
            monitors.append(monitor)
        }
    }

    /// Pressure events come with every trackpad press; stage 2 is the "deep"
    /// click macOS uses for Force Click. Global monitors aren't sent them,
    /// but a listen-only event tap is. They arrive as trackpad gesture events
    /// (type 29), which NSEvent turns into `.pressure`.
    private func installTap() {
        let gesture = UInt64(29)  // kCGEventGesture, not in CGEventType
        let mask = (CGEventMask(1) << gesture) | (CGEventMask(1) << UInt64(NSEvent.EventType.pressure.rawValue))
        let callback: CGEventTapCallBack = { _, type, event, info in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                // macOS pauses a tap that answers too slowly; switch it back on.
                if let info {
                    let presenter = Unmanaged<ArtworkCardPresenter>.fromOpaque(info).takeUnretainedValue()
                    MainActor.assumeIsolated {
                        if let tap = presenter.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    }
                }
                return Unmanaged.passUnretained(event)
            }
            if let info, let nsEvent = NSEvent(cgEvent: event), nsEvent.type == .pressure {
                let presenter = Unmanaged<ArtworkCardPresenter>.fromOpaque(info).takeUnretainedValue()
                MainActor.assumeIsolated { presenter.handlePressure(nsEvent) }
            }
            return Unmanaged.passUnretained(event)
        }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                eventsOfInterest: mask, callback: callback,
                                userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { return }
        tapSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func removeTap() {
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        tap = nil
        tapSource = nil
    }

    private func handlePressure(_ event: NSEvent) {
        let previous = stage
        stage = event.stage
        guard event.stage == 2, previous < 2, Desktop.isUnderPointer(),
              let screen = Desktop.screenUnderPointer()
        else { return }
        show(on: screen)
    }

    private func show(on screen: NSScreen) {
        let index = NSScreen.screens.firstIndex(of: screen) ?? 0
        let showing = controller.current.first { $0.id == index } ?? controller.current.first
        guard let artwork = showing?.artwork else { return }
        close()

        let panel = CardPanel(content: ArtworkCard(controller: controller, artwork: artwork) { [weak self] in
            self?.close()
        })
        panel.onCancel = { [weak self] in self?.close() }
        panel.place(near: NSEvent.mouseLocation, on: screen)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)  // key so Esc reaches it; non-activating, so focus stays put
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }
        self.panel = panel
    }

    private func close() {
        guard let panel else { return }
        self.panel = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.close()
        })
    }
}

// MARK: - Panel

@MainActor
private final class CardPanel: NSPanel {
    var onCancel: (() -> Void)?

    init<Content: View>(content: Content) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.transient, .ignoresCycle, .moveToActiveSpace]
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false

        let hosting = NSHostingView(rootView: content)
        hosting.setFrameSize(hosting.fittingSize)
        contentView = hosting
        setContentSize(hosting.fittingSize)
    }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }

    /// Just below and to the right of `point`, flipped to stay on screen.
    func place(near point: NSPoint, on screen: NSScreen) {
        let size = frame.size
        let bounds = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        var origin = NSPoint(x: point.x + 14, y: point.y - 14 - size.height)
        if origin.x + size.width > bounds.maxX { origin.x = point.x - 14 - size.width }
        if origin.y < bounds.minY { origin.y = point.y + 14 }
        origin.x = min(max(origin.x, bounds.minX), bounds.maxX - size.width)
        origin.y = min(max(origin.y, bounds.minY), bounds.maxY - size.height)
        setFrameOrigin(origin)
    }
}

// MARK: - Card

private struct ArtworkCard: View {
    @ObservedObject var controller: WallpaperController
    let artwork: Artwork
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(artwork.title)
                .font(.system(size: 24, weight: .bold, design: .serif))
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 12)

            VStack(alignment: .leading, spacing: 3) {
                if !artwork.date.isEmpty { Text(artwork.date) }
                if !artwork.artist.isEmpty { Text(artwork.artist) }
            }
            .font(.system(size: 14))

            if let bio = artwork.bio {
                Text("Artist, \(bio)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.top, 3)
            }

            if let medium = artwork.medium {
                Text(medium.prefix(1).uppercased() + medium.dropFirst())
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }

            Divider().padding(.vertical, 14)

            HStack {
                Link(destination: artwork.pageURL) {
                    Label("Read more on nga.gov", systemImage: "arrow.up.right")
                        .labelStyle(TrailingIconLabelStyle())
                }
                .simultaneousGesture(TapGesture().onEnded { dismiss() })
                Spacer()
                favoriteButton
            }
            .font(.system(size: 12, weight: .medium))

            // The Gallery's suggested credit for its open access images.
            Link(destination: Artwork.openAccessPolicy) {
                Label {
                    Text("Public domain (CC0) · Courtesy National Gallery of Art, Washington")
                } icon: {
                    Text("0")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .frame(width: 13, height: 13)
                        .overlay(Circle().strokeBorder(lineWidth: 1.2))
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            }
            .help("Read the Gallery's Open Access policy")
            .padding(.top, 12)
        }
        .padding(22)
        .frame(width: 340, alignment: .leading)
        .background(VisualEffect().clipShape(RoundedRectangle(cornerRadius: 14)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.08)))
    }

    @ViewBuilder private var favoriteButton: some View {
        let isFavorite = controller.isFavorite(artwork)
        Button {
            controller.toggleFavorite(artwork)
        } label: {
            Image(systemName: isFavorite ? "heart.fill" : "heart")
                .foregroundStyle(isFavorite ? Color.pink : Color.secondary)
                .font(.system(size: 15))
        }
        .buttonStyle(.borderless)
        .disabled(!isFavorite && controller.favoritesFull)
        .help(isFavorite ? "Remove from Favorites"
              : controller.favoritesFull ? "Favorites are full (\(WallpaperController.favoritesLimit) max)"
              : "Add to Favorites")
    }
}

private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.title
            configuration.icon.imageScale(.small)
        }
    }
}

private struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
