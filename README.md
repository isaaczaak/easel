<p align="center">
  <img src="docs/icon.png" width="128" height="128" alt="Easel app icon">
</p>

<h1 align="center">Easel</h1>

<p align="center">
  Easel lives in your menu bar and rotates 20,000 public-domain works from the
  <a href="https://www.nga.gov/artworks/free-images-and-open-access">National Gallery of Art</a>
  as your wallpaper, fetched at full resolution for every screen.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-13%2B-111?logo=apple&logoColor=white" alt="macOS 13+">
  <img src="https://img.shields.io/badge/Apple%20Silicon%20%2B%20Intel-Universal-111" alt="Universal binary">
  <img src="https://img.shields.io/badge/Swift-SwiftUI-F05138?logo=swift&logoColor=white" alt="Swift and SwiftUI">
  <img src="https://img.shields.io/badge/code-MIT-3d7a5c" alt="MIT license">
  <img src="https://img.shields.io/badge/artwork-CC0-c9a24b" alt="Artwork CC0">
</p>

<p align="center">
  <img src="docs/hero.webp" alt="Three paintings from the collection" width="100%">
  <br>
  <sub>
    <em>Wivenhoe Park, Essex</em>, John Constable, 1816 ·
    <em>Farmhouse in Provence</em>, Vincent van Gogh, 1888 ·
    <em>Watson and the Shark</em>, John Singleton Copley, 1778
  </sub>
</p>

## Features

- Rotates every 15 minutes, hour, 3 hours or day, and on wake
- Same artwork everywhere, or different art on each display
- Filter by kind (paintings, drawings, prints, photographs, sculpture) and by
  dominant color
- Hide nudity (on by default), using NGA's tags plus CLIP image analysis
- Favorites, previous/next, launch at login
- Universal binary (Apple Silicon + Intel), macOS 13+

## Build & install (this Mac)

    scripts/bundle.sh --install    # → /Applications/Easel.app (ad-hoc signed)

## Refresh the artwork list

    scripts/build_manifest.py      # NGA CSVs → Resources/manifest.json
    scripts/analyze_colors.py      # color tags (cached in .data/colors.json), then rebuilds

    # Nudity scores with CLIP (cached in .data/nudity.json), then rebuilds
    python3 -m venv .data/venv && .data/venv/bin/pip install torch open_clip_torch pillow
    .data/venv/bin/python scripts/detect_nudity.py

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

## License

Code is MIT (see `LICENSE`). Artwork images and collection data come from the
National Gallery of Art's open access program and are CC0.
