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
            .disabled(!controller.canGoBack)
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
    private static let toggle = SwitchTarget()

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
                guard let menu = note.object as? NSMenu,
                      let item = menu.items.first, item.title == title
                else { return }
                isOpen = true
                if item.view == nil { item.view = makeView() }
                toggle.control?.state = controller.isOn ? .on : .off
                markCurrentScreen(in: menu, controller: controller)
            }
        })
    }

    /// In per-display mode, draws each display's label with a small black
    /// dot after the one the menu was opened on. Plain menu text is always
    /// greyed out, so the labels get custom views like the header.
    private static func markCurrentScreen(in menu: NSMenu, controller: WallpaperController) {
        let here = Desktop.screenUnderPointer().flatMap { NSScreen.screens.firstIndex(of: $0) }
        for showing in controller.current where !showing.screenName.isEmpty {
            guard let item = menu.items.first(where: { $0.title == showing.screenName }) else { continue }
            item.view = screenLabel(showing.screenName, isHere: showing.id == here)
        }
    }

    private static func screenLabel(_ name: String, isHere: Bool) -> NSView {
        let label = NSTextField(labelWithString: name)
        label.font = .menuFont(ofSize: 0)
        label.textColor = .tertiaryLabelColor  // as macOS draws a disabled item
        label.translatesAutoresizingMaskIntoConstraints = false

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
        view.autoresizingMask = [.width]
        view.addSubview(label)
        var constraints = [
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 15),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ]
        if isHere {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.backgroundColor = NSColor.labelColor.cgColor
            dot.layer?.cornerRadius = 2.5
            dot.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(dot)
            constraints += [
                dot.widthAnchor.constraint(equalToConstant: 5),
                dot.heightAnchor.constraint(equalToConstant: 5),
                dot.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 6),
                dot.centerYAnchor.constraint(equalTo: label.centerYAnchor, constant: 0.5),
            ]
        }
        NSLayoutConstraint.activate(constraints)
        return view
    }

    private final class SwitchTarget: NSObject {
        weak var control: NSSwitch?

        @objc func flip(_ sender: NSSwitch) {
            MainActor.assumeIsolated {
                MenuHeader.controller?.isOn = sender.state == .on
            }
        }
    }

    private static func makeView() -> NSView {
        let label = NSTextField(labelWithString: title)
        // Same size as the menu's items, in bold, like Bluetooth's header.
        label.font = .systemFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize, weight: .bold)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        let control = NSSwitch()
        control.controlSize = .small
        control.target = toggle
        control.action = #selector(SwitchTarget.flip(_:))
        control.translatesAutoresizingMaskIntoConstraints = false
        toggle.control = control

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 32))
        view.autoresizingMask = [.width]
        view.addSubview(label)
        view.addSubview(control)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 15),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: 1),
            control.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            control.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        return view
    }
}
