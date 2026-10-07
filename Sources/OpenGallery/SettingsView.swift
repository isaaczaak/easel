import SwiftUI

/// Opens the Settings window and brings it forward. OpenGallery has no Dock
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
            FavoritesSettings(controller: controller)
                .tabItem { Label("Favorites", systemImage: "heart") }
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
            } header: {
                Text("Rotation")
            } footer: {
                Text("OpenGallery also changes the artwork when your Mac wakes, if the interval has passed.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Swipe to change artwork", isOn: $controller.swipeEnabled)
                Toggle(isOn: $controller.forceClickEnabled) {
                    Text("Force Click for artwork details")
                    Text("Requires Input Monitoring access in Privacy & Security settings")
                }
                if controller.forceClickEnabled {
                    InputMonitoringStatus()
                }
            } header: {
                Text("On the desktop")
            } footer: {
                Text("Swipe with two fingers to change artwork. Press firmly for details.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { controller.launchAtLogin },
                    set: { controller.setLaunchAtLogin($0) }
                ))
            } footer: {
                CreditFooter()
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
            Section("Type") {
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
                MovementPicker(controller: controller)
            } footer: {
                Text("Only some works are tagged with a movement, so choosing one narrows the selection.")
                    .foregroundStyle(.secondary)
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
                VStack(alignment: .leading, spacing: 12) {
                    Text("Hides artworks the gallery tags as nude, plus others flagged by image analysis. Some nudity may still appear.")
                        .foregroundStyle(.secondary)
                    CreditFooter()
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// One row with a drop-down of movements to tick, instead of a long grid.
private struct MovementPicker: View {
    @ObservedObject var controller: WallpaperController

    private var summary: String {
        let chosen = ArtMovement.allCases.filter { controller.movements.contains($0.rawValue) }
        switch chosen.count {
        case 0: return "Any"
        case 1: return chosen[0].rawValue
        default: return "\(chosen.count) movements"
        }
    }

    var body: some View {
        LabeledContent("Art movement") {
            Menu(summary) {
                Toggle("Any", isOn: Binding(
                    get: { controller.movements.isEmpty },
                    set: { if $0 { controller.movements = [] } }
                ))
                Divider()
                let counts = controller.movementCounts
                ForEach(ArtMovement.allCases) { movement in
                    Toggle("\(movement.rawValue)  (\(counts[movement.rawValue, default: 0]))", isOn: Binding(
                        get: { controller.movements.contains(movement.rawValue) },
                        set: { controller.setMovement(movement, enabled: $0) }
                    ))
                }
            }
            .fixedSize()
        }
    }
}

private struct FavoritesSettings: View {
    @ObservedObject var controller: WallpaperController

    var body: some View {
        Form {
            Section {
                Toggle("Favorites only", isOn: $controller.favoritesOnly)
                    .disabled(controller.favorites.isEmpty && !controller.favoritesOnly)
                FavoritesList(controller: controller)
            } header: {
                Text("Favorites (\(controller.favorites.count) of \(WallpaperController.favoritesLimit))")
            } footer: {
                CreditFooter()
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Favorites, newest first, scrolling once there are more than a few.
private struct FavoritesList: View {
    @ObservedObject var controller: WallpaperController

    var body: some View {
        let favorites = controller.favoriteArtworks
        if favorites.isEmpty {
            Text("Choose Add to Favorites in the menu bar to keep artwork you like here.")
                .foregroundStyle(.secondary)
        } else {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(favorites) { artwork in
                        FavoriteRow(artwork: artwork) { controller.toggleFavorite(artwork) }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(height: min(CGFloat(favorites.count) * 50, 250))
        }
    }
}

private struct FavoriteRow: View {
    let artwork: Artwork
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            AsyncImage(url: artwork.imageURL(width: 200)) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.secondary.opacity(0.15)
            }
            .frame(width: 56, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 2) {
                Link(artwork.menuTitle, destination: artwork.pageURL)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !artwork.menuByline.isEmpty {
                    Text(artwork.menuByline)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Remove from Favorites")
        }
    }
}

/// Force Click needs Input Monitoring; offers the way to switch it on.
private struct InputMonitoringStatus: View {
    @State private var granted = CGPreflightListenEventAccess()
    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if !granted {
                HStack {
                    Label("Needs Input Monitoring permission", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Open Privacy Settings…") {
                        NSWorkspace.shared.open(URL(string:
                            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
                    }
                }
            }
        }
        .onReceive(refresh) { _ in granted = CGPreflightListenEventAccess() }
    }
}

/// The Gallery's suggested credit, shown at the bottom of each tab.
private struct CreditFooter: View {
    var body: some View {
        Text(Self.text)
            .foregroundStyle(.secondary)
    }

    /// Built as an attributed string so the link keeps the policy URL exactly.
    private static let text: AttributedString = {
        var text = AttributedString("Public domain artwork (CC0), courtesy National Gallery of Art, Washington. OpenGallery isn't affiliated with the Gallery.")
        if let range = text.range(of: "CC0") {
            text[range].link = Artwork.openAccessPolicy
        }
        return text
    }()
}
