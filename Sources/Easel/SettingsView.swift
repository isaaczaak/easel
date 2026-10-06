import SwiftUI

/// Opens the Settings window and brings it forward. Easel has no Dock
/// icon, so it must activate itself or the window opens behind other apps.
struct SettingsButton: View {
    var body: some View {
        if #available(macOS 14, *) {
            ModernSettingsButton()
        } else {
            Button("Settings…") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                bringSettingsToFront()
            }
            .keyboardShortcut(",")
        }
    }
}

@available(macOS 14, *)
private struct ModernSettingsButton: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Settings…") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
            bringSettingsToFront()
        }
        .keyboardShortcut(",")
    }
}

/// The window appears a moment after it's requested; raise it once it exists.
@MainActor
private func bringSettingsToFront() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows
            .first { $0.identifier?.rawValue.contains("Settings") == true }?
            .makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var controller: WallpaperController

    var body: some View {
        TabView {
            GeneralSettings(controller: controller)
                .tabItem { Label("General", systemImage: "gearshape") }
            ArtworkSettings(controller: controller)
                .tabItem { Label("Artwork", systemImage: "photo.artframe") }
        }
        .frame(width: 460)
    }
}

private struct GeneralSettings: View {
    @ObservedObject var controller: WallpaperController

    var body: some View {
        Form {
            Section {
                Picker("Change artwork every", selection: $controller.interval) {
                    ForEach(RotationInterval.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Different art on each display", isOn: $controller.perDisplay)
            } footer: {
                Text("Easel also changes the artwork when your Mac wakes, if the interval has passed.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { controller.launchAtLogin },
                    set: { controller.setLaunchAtLogin($0) }
                ))
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ArtworkSettings: View {
    @ObservedObject var controller: WallpaperController

    private let columns = [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)]

    var body: some View {
        Form {
            Section("Show") {
                Toggle("All kinds", isOn: Binding(
                    get: { controller.showsAllKinds },
                    set: { controller.setAllKinds($0) }
                ))
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(ArtKind.allCases) { kind in
                        Toggle(kind.label, isOn: Binding(
                            get: { controller.enabledKinds.contains(kind.rawValue) },
                            set: { controller.setKind(kind, enabled: $0) }
                        ))
                        .toggleStyle(.checkbox)
                    }
                }
            }
            Section {
                Toggle("Any color", isOn: Binding(
                    get: { controller.palettes.isEmpty },
                    set: { if $0 { controller.palettes = [] } }
                ))
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(PaletteColor.allCases) { color in
                        Toggle(isOn: Binding(
                            get: { controller.palettes.contains(color.rawValue) },
                            set: { controller.setPalette(color, enabled: $0) }
                        )) {
                            HStack(spacing: 6) {
                                Image(nsImage: color.swatch)
                                Text(color.label)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            } header: {
                Text("Palette")
            } footer: {
                Text("Shows artworks where any selected color is prominent.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Hide nudity", isOn: $controller.hideNudity)
            } footer: {
                Text("Hides artworks the gallery tags as nude, plus others flagged by image analysis. Some nudity may still appear.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Favorites only", isOn: $controller.favoritesOnly)
            } footer: {
                Text("Artwork from the [National Gallery of Art's open access collection](https://www.nga.gov/artworks/free-images-and-open-access), released under CC0.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}
