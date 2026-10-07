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
    <em>The Bridge at Argenteuil</em>, Claude Monet, 1874
  </sub>
</p>

## Features

**Rotation:** Changes the artwork every hour by default. Change it to every
15 minutes, 3 hours or day, and show the same artwork on every display or
different art on each.

**Filters:** Choose by type, art movement and palette. Nudity is hidden by
default, using the Gallery's own tags plus image analysis.

**Desktop gestures:** Swipe sideways with two fingers to see the next or
previous artwork. Force Click to open the artwork's details.

**Favorites:** Keep up to 20, and show only those if you like.

**On/off:** Switch OpenGallery off from its menu to get your old wallpaper
back.

Runs on Apple Silicon and Intel Macs with macOS 13 or later.

## Install

Requires macOS 13 or later and Apple's command line tools
(`xcode-select --install`, which includes Swift).

```bash
git clone https://github.com/isaaczaak/opengallery.git
cd opengallery
scripts/bundle.sh --install
```

This builds OpenGallery, copies it to `/Applications` and launches it. It
appears in your menu bar and starts at login. Because you built it yourself,
macOS opens it without a security warning.

Force Click is off by default. It needs the Input Monitoring permission, which
OpenGallery asks for when you turn it on; you can also grant it in System
Settings → Privacy & Security → Input Monitoring.

To update, run `git pull` and `scripts/bundle.sh --install` again. If Force
Click stops working after an update, allow OpenGallery again under Input
Monitoring: macOS ties the permission to each build. To remove it, quit
OpenGallery from its menu and delete `/Applications/OpenGallery.app`.

### Agent prompt

Or paste this into a coding agent such as Claude Code:

```text
Install OpenGallery, a macOS menu bar app, from
https://github.com/isaaczaak/opengallery.

1. Check this Mac runs macOS 13 or later (sw_vers). If `swift --version`
   fails, run `xcode-select --install`, wait for me to finish the installer,
   then continue.
2. Clone the repo into ~/Code/opengallery (or update it with git pull if it's
   already there) and run `scripts/bundle.sh --install` from inside it.
3. Confirm OpenGallery is running (pgrep -x OpenGallery) and tell me to look
   for its icon in the menu bar.
4. Tell me that Force Click artwork details is optional and off by default:
   to use it, I turn it on in OpenGallery's Settings and allow OpenGallery
   under System Settings → Privacy & Security → Input Monitoring. After a
   future update I may need to allow it again.

Don't use sudo, and don't change any other system or privacy settings.
```

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

## Developing

Each rebuild gets a new signature, so macOS forgets OpenGallery's Input
Monitoring permission. If you rebuild often, `scripts/make_signing_cert.sh`
creates a self-signed certificate in your login keychain, trusted only for
code signing, that `bundle.sh` then signs with, so the permission sticks. Any
program running as you could also sign with it and take over that
permission; delete it in Keychain Access to undo.

## License

Code is MIT (see `LICENSE`). Artwork images and collection data come from the
National Gallery of Art's [open access program](https://www.nga.gov/artworks/free-images-and-open-access):
images of works the Gallery believes to be in the public domain are released
under [CC0](https://www.nga.gov/terms-and-notices#open-access), as is the
collection data. Artwork courtesy National Gallery of Art, Washington. OpenGallery is
not affiliated with or endorsed by the National Gallery of Art.
