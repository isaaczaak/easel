#!/bin/bash
# Build OpenGallery and publish it on GitHub Releases as a zip, with the
# changelog from docs/releases/v<version>.md followed by install steps.
#   scripts/release.sh 0.3.0                 build and publish
#   scripts/release.sh 0.2.0 --notes-only    rewrite an existing release's notes
# Releases are ad-hoc signed, not notarized: macOS asks people to allow the
# app once in System Settings. Notarizing needs an Apple Developer ID.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version> [--notes-only]}"
TAG="v$VERSION"
CHANGES="docs/releases/$TAG.md"

if [ ! -f "$CHANGES" ]; then
    echo "Write the changelog in $CHANGES first." >&2
    exit 1
fi

notes() {
    cat "$CHANGES"
    cat <<NOTES

## Install

Download **OpenGallery-$VERSION.zip**, unzip it and move OpenGallery to
Applications. It needs macOS 13 or later and runs on Apple Silicon and Intel.
The first time, macOS blocks it because it isn't notarized: open it once, then
click **Open Anyway** in System Settings → Privacy & Security.

To update, quit OpenGallery from its menu and replace the app. If you use
Force Click, allow OpenGallery again under Input Monitoring.
NOTES
}

# Update an existing release's notes without rebuilding it.
if [ "${2:-}" = "--notes-only" ]; then
    notes | gh release edit "$TAG" --notes-file -
    echo "Updated notes for $TAG"
    exit 0
fi

if [ -n "$(git status --porcelain)" ]; then
    echo "Commit your changes first." >&2
    exit 1
fi
git fetch -q origin main
if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
    echo "Release from main, pushed and up to date." >&2
    exit 1
fi

VERSION="$VERSION" SIGN_ID="-" scripts/bundle.sh
ZIP="build/OpenGallery-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent build/OpenGallery.app "$ZIP"

notes | gh release create "$TAG" "$ZIP" --target main --title "OpenGallery $VERSION" --notes-file -
echo "Published $TAG"
