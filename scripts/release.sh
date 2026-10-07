#!/bin/bash
# Build OpenGallery and publish it on GitHub Releases as a zip.
#   scripts/release.sh 0.1.0
# Releases are ad-hoc signed, not notarized: macOS asks people to allow the
# app once in System Settings. Notarizing needs an Apple Developer ID.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version>}"
TAG="v$VERSION"

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

gh release create "$TAG" "$ZIP" --target main --title "OpenGallery $VERSION" --notes-file - <<NOTES
Download **OpenGallery-$VERSION.zip**, unzip it and move **OpenGallery** to
your Applications folder. Requires macOS 13 or later, on Apple Silicon or Intel.

**First open:** OpenGallery isn't notarized by Apple yet, so macOS blocks it
the first time. Open it once, then go to System Settings → Privacy & Security,
scroll down and click **Open Anyway**.

**Updating:** quit OpenGallery from its menu, then replace the app with the
new version. If you use Force Click, allow OpenGallery again under
Privacy & Security → Input Monitoring.
NOTES
echo "Published $TAG"
