import AppKit
import SwiftUI

@main
struct EaselApp: App {
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start()
    }
}

struct MenuContent: View {
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
                    Button(controller.isFavorite(showing.artwork) ? "Remove from Favorites" : "Add to Favorites") {
                        controller.toggleFavorite(showing.artwork)
                    }
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
            Button(controller.isFavorite(artwork) ? "Remove from Favorites" : "Add to Favorites") {
                controller.toggleFavorite(artwork)
            }
            .keyboardShortcut("f")
        }

        Divider()

        Toggle("Pause Rotation", isOn: $controller.paused)

        Divider()

        SettingsButton()
        Button("Quit Easel") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
