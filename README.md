# Easel

A macOS menu bar app that rotates your desktop wallpaper through open-access
artworks from the [National Gallery of Art](https://www.nga.gov/artworks/free-images-and-open-access) (CC0).

- Rotates every 15 minutes, hour, 3 hours or day, and on wake
- Same artwork everywhere, or different art on each display
- Filter by kind (paintings, drawings, prints, photographs, sculpture) and by
  dominant color
- Favorites, previous/next, launch at login
- Universal binary (Apple Silicon + Intel), macOS 13+

## Build & install (this Mac)

    scripts/bundle.sh --install    # → /Applications/Easel.app (ad-hoc signed)

## Refresh the artwork list

    scripts/build_manifest.py      # NGA CSVs → Resources/manifest.json
    scripts/analyze_colors.py      # color tags (cached in .data/colors.json), then rebuilds

The manifest keeps open-access, primary-view, landscape images at least
2000px wide. Images are fetched at screen resolution from NGA's IIIF server
and cached in `~/Library/Caches` (newest 20 kept).

## App icon

    swift scripts/make_icon.swift  # current icon → Resources/AppIcon.icns

`icon/index.html` is a three.js renderer for 3D icon explorations; run
`icon/serve.py` and open http://localhost:8765/icon/index.html.

## Layout

- `Sources/Easel/` — SwiftUI `MenuBarExtra` app and Settings window
- `scripts/` — manifest, color analysis, icon and bundling scripts
- `Resources/` — manifest and icon assets bundled into the app

## Not yet

Developer ID signing and notarization, Sparkle updates, hosted manifest.
