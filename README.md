<p align="center">
  <img src="docs/icon.png" width="128" height="128" alt="OpenGallery app icon">
</p>

<h1 align="center">OpenGallery</h1>

<p align="center">
  OpenGallery lives in your menu bar and rotates 20,000 public-domain works from the
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
- Swipe sideways with two fingers on the desktop to change the artwork on
  that screen
- Force Click the desktop for the artwork's label: title, artist, date and
  medium (needs the Input Monitoring permission)
- Favorites (up to 20), previous/next, launch at login
- Universal binary (Apple Silicon + Intel), macOS 13+

## Install

Requires macOS 13 or later and Apple's command line tools
(`xcode-select --install`, which includes Swift).

```bash
git clone https://github.com/isaaczaak/opengallery.git
cd opengallery
scripts/bundle.sh --install
```

This builds OpenGallery, copies it to `/Applications` and launches it. It appears in
your menu bar and starts at login. Because you built it yourself, macOS opens
it without a security warning.

To update, run `git pull` and `scripts/bundle.sh --install` again. To remove
it, quit OpenGallery from its menu and delete `/Applications/OpenGallery.app`.

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

- `Sources/OpenGallery/` — SwiftUI `MenuBarExtra` app and Settings window
- `scripts/` — manifest, color analysis, icon and bundling scripts
- `Resources/` — manifest and icon assets bundled into the app

## Not yet

Developer ID signing and notarization, Sparkle updates, hosted manifest.

## License

Code is MIT (see `LICENSE`). Artwork images and collection data come from the
National Gallery of Art's [open access program](https://www.nga.gov/artworks/free-images-and-open-access):
images of works the Gallery believes to be in the public domain are released
under [CC0](https://www.nga.gov/terms-and-notices#open-access), as is the
collection data. Artwork courtesy National Gallery of Art, Washington. OpenGallery is
not affiliated with or endorsed by the National Gallery of Art.
