import AppKit
import Combine
import SwiftUI

@main
struct OpenGalleryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: appDelegate.controller)
        } label: {
            Image(nsImage: MenuBarIcon.image)
        }
        Settings {
            SettingsView(controller: appDelegate.controller)
        }
    }
}

/// Owns the controller so rotation starts at launch, not when the menu first opens.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = WallpaperController()
    private lazy var swiper = DesktopSwiper(controller: controller)
    private lazy var card = ArtworkCardPresenter(controller: controller)

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start()
        swiper.start()
        card.start()
        MenuHeader.install(controller: controller)
    }
}

struct MenuContent: View {
    @ObservedObject var controller: WallpaperController
    @ObservedObject private var layout = MenuHeader.layout

    var body: some View {
        Text(MenuHeader.title)
        Divider()

        if layout.showsArtwork {
            ArtworkMenuItems(controller: controller)
                .disabled(!controller.isOn)
        }

        SettingsButton()
        Button("Quit OpenGallery") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// Everything about the artwork, shown while OpenGallery is on.
private struct ArtworkMenuItems: View {
    @ObservedObject var controller: WallpaperController

    var body: some View {
        if controller.current.count == 1, let artwork = controller.current.first?.artwork {
            Text(artwork.menuTitle)
            if !artwork.menuByline.isEmpty {
                Text(artwork.menuByline)
            }
            Button("View at National Gallery of Art…") {
                NSWorkspace.shared.open(artwork.pageURL)
            }
        } else {
            // One submenu per display, so the top of the menu stays compact.
            ForEach(controller.current) { showing in
                Text(showing.screenName)
                    .font(.caption)
                Menu(showing.artwork.menuTitle) {
                    if !showing.artwork.menuByline.isEmpty {
                        Text(showing.artwork.menuByline)
                    }
                    Divider()
                    Button("View at National Gallery of Art…") {
                        NSWorkspace.shared.open(showing.artwork.pageURL)
                    }
                    FavoriteButton(controller: controller, artwork: showing.artwork)
                }
            }
        }
        if let status = controller.status {
            Text(status)
        }

        Divider()

        Button("Next Artwork") { controller.next() }
            .keyboardShortcut("n")
        Button("Previous Artwork") { controller.previous() }
            .keyboardShortcut("p")
            .disabled(!controller.canGoBack())
        if controller.current.count == 1, let artwork = controller.current.first?.artwork {
            FavoriteButton(controller: controller, artwork: artwork)
                .keyboardShortcut("f")
        }

        Divider()

        Toggle("Pause Rotation", isOn: $controller.paused)

        Divider()
    }
}

private struct FavoriteButton: View {
    @ObservedObject var controller: WallpaperController
    let artwork: Artwork

    var body: some View {
        if controller.isFavorite(artwork) {
            Button("Remove from Favorites") { controller.toggleFavorite(artwork) }
        } else if controller.favoritesFull {
            Button("Favorites Full (\(WallpaperController.favoritesLimit) Max)") {}
                .disabled(true)
        } else {
            Button("Add to Favorites") { controller.toggleFavorite(artwork) }
        }
    }
}

/// Shows the menu's first item ("OpenGallery") as a bold title with an on/off
/// switch, like Bluetooth's menu. SwiftUI menus draw plain text as a grey
/// disabled item, so the item gets a custom view each time the menu opens.
@MainActor
enum MenuHeader {
    static let title = "OpenGallery"
    private static var observers: [Any] = []
    private static var isOnObserver: AnyCancellable?
    private static weak var controller: WallpaperController?
    private static weak var toggle: AccentSwitch?

    /// Whether the menu lists the artwork. Flipping the switch while the
    /// menu is open only greys the items out, so the menu doesn't jump in
    /// size; they're added or removed the next time it opens.
    final class Layout: ObservableObject {
        @Published var showsArtwork = true
    }
    static let layout = Layout()
    private static var isOpen = false

    static func install(controller: WallpaperController) {
        self.controller = controller
        layout.showsArtwork = controller.isOn
        isOnObserver = controller.$isOn.sink { isOn in
            if !isOpen { layout.showsArtwork = isOn }
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main
        ) { note in
            MainActor.assumeIsolated {
                guard let menu = note.object as? NSMenu, menu.items.first?.title == title else { return }
                isOpen = false
                layout.showsArtwork = controller.isOn
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { note in
            MainActor.assumeIsolated {
                guard let menu = note.object as? NSMenu, menu.items.first?.title == title else { return }
                isOpen = true
                hereScreen = Desktop.screenUnderPointer().flatMap { NSScreen.screens.firstIndex(of: $0) }
                decorate(menu)
                toggle?.setOn(controller.isOn, animated: false)
            }
        })
        // SwiftUI can add or rebuild items just after the menu opens, which
        // drops the custom views; put them back whenever the items change.
        for name in [NSMenu.didAddItemNotification, NSMenu.didChangeItemNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                MainActor.assumeIsolated {
                    guard let menu = note.object as? NSMenu, menu.items.first?.title == title else { return }
                    decorate(menu)
                }
            })
        }
    }

    /// The display the menu was opened on.
    private static var hereScreen: Int?
    private static var decorating = false

    /// Gives the header and the display labels their custom views, only
    /// where missing or out of date (setting a view posts another change).
    private static func decorate(_ menu: NSMenu) {
        guard !decorating, let controller, let header = menu.items.first else { return }
        decorating = true
        defer { decorating = false }
        if header.view == nil {
            header.view = makeView()
            toggle?.setOn(controller.isOn, animated: false)
        }
        markCurrentScreen(in: menu, controller: controller)
    }

    /// In per-display mode, draws each display's label with a small black
    /// dot after the one the menu was opened on. Plain menu text is always
    /// greyed out, so the labels get custom views like the header.
    private static func markCurrentScreen(in menu: NSMenu, controller: WallpaperController) {
        for showing in controller.current where !showing.screenName.isEmpty {
            guard let item = menu.items.first(where: { $0.title == showing.screenName }) else { continue }
            let id = NSUserInterfaceItemIdentifier(showing.id == hereScreen ? "here" : "label")
            guard item.view?.identifier != id else { continue }
            let view = screenLabel(showing.screenName, isHere: showing.id == hereScreen)
            view.identifier = id
            item.view = view
        }
    }

    /// A menu row holding `label`, inset like the menu's own items.
    private static func menuRow(_ label: NSTextField, height: CGFloat) -> NSView {
        label.translatesAutoresizingMaskIntoConstraints = false
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: height))
        view.autoresizingMask = [.width]
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 15),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: 0.5),
        ])
        return view
    }

    private static func screenLabel(_ name: String, isHere: Bool) -> NSView {
        let label = NSTextField(labelWithString: name)
        label.font = .menuFont(ofSize: 0)
        label.textColor = .tertiaryLabelColor  // as macOS draws a disabled item
        let view = menuRow(label, height: 22)
        if isHere {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.backgroundColor = NSColor.labelColor.cgColor
            dot.layer?.cornerRadius = 2.5
            dot.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(dot)
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 5),
                dot.heightAnchor.constraint(equalToConstant: 5),
                dot.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 6),
                dot.centerYAnchor.constraint(equalTo: label.centerYAnchor, constant: 0.5),
            ])
        }
        return view
    }

    private static func makeView() -> NSView {
        let label = NSTextField(labelWithString: title)
        // Same size as the menu's items, in bold, like Bluetooth's header.
        label.font = .systemFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize, weight: .bold)
        label.textColor = .labelColor
        let view = menuRow(label, height: 32)

        let control = AccentSwitch()
        control.onChange = { isOn in MenuHeader.controller?.isOn = isOn }
        control.translatesAutoresizingMaskIntoConstraints = false
        toggle = control
        view.addSubview(control)
        NSLayoutConstraint.activate([
            control.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            control.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        return view
    }
}

/// A switch in the system accent color. NSSwitch draws grey inside a menu,
/// because the menu's window is never active.
@MainActor
private final class AccentSwitch: NSView {
    var onChange: ((Bool) -> Void)?
    private(set) var isOn = false
    private let track = CALayer()
    private let knob = CALayer()
    private static let size = NSSize(width: 36, height: 20)

    override init(frame: NSRect) {
        super.init(frame: NSRect(origin: frame.origin, size: Self.size))
        wantsLayer = true
        track.cornerRadius = Self.size.height / 2
        knob.backgroundColor = NSColor.white.cgColor
        knob.cornerRadius = (Self.size.height - 4) / 2
        knob.shadowColor = NSColor.black.cgColor
        knob.shadowOpacity = 0.25
        knob.shadowRadius = 1.5
        knob.shadowOffset = CGSize(width: 0, height: -0.5)
        layer?.addSublayer(track)
        layer?.addSublayer(knob)
        setOn(false, animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { Self.size }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        setOn(!isOn, animated: true)
        onChange?(isOn)
    }

    func setOn(_ on: Bool, animated: Bool) {
        isOn = on
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.2)
        let height = Self.size.height
        track.frame = CGRect(origin: .zero, size: Self.size)
        knob.frame = CGRect(x: on ? Self.size.width - height + 2 : 2, y: 2, width: height - 4, height: height - 4)
        updateColors()
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            track.backgroundColor = (isOn ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(0.15)).cgColor
        }
    }
}
