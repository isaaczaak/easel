#!/bin/bash
# Releases OpenGallery. GitHub builds it, not this Mac: tagging a version
# starts .github/workflows/release.yml, which builds the app from the tagged
# source, attaches a signed record of that (build provenance) and publishes
# the zip on GitHub Releases with the changelog from docs/releases/.
#   scripts/release.sh 0.3.0                 tag and publish
#   scripts/release.sh 0.2.0 --notes-only    rewrite an existing release's notes
# Releases are ad-hoc signed, not notarized: macOS asks people to allow the
# app once in System Settings. Notarizing needs an Apple Developer ID.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version> [--notes-only]}"
TAG="v$VERSION"
scripts/release_notes.sh "$VERSION" >/dev/null  # changelog exists

if [ "${2:-}" = "--notes-only" ]; then
    scripts/release_notes.sh "$VERSION" | gh release edit "$TAG" --notes-file -
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

git tag "$TAG"
git push -q origin "$TAG"
echo "Tagged $TAG. GitHub is building it: https://github.com/isaaczaak/opengallery/actions"
