#!/bin/bash
# Prints a release's notes: the changelog in docs/releases/v<version>.md,
# then install steps. Used by scripts/release.sh and the release workflow.
#   scripts/release_notes.sh 0.3.0
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release_notes.sh <version>}"
CHANGES="docs/releases/v$VERSION.md"
if [ ! -f "$CHANGES" ]; then
    echo "Write the changelog in $CHANGES first." >&2
    exit 1
fi

cat "$CHANGES"
cat <<NOTES

## Install

Download **OpenGallery-$VERSION.zip**, unzip it and move OpenGallery to
Applications. It needs macOS 13 or later and runs on Apple Silicon and Intel.
The first time, macOS blocks it because it isn't notarized: open it once, then
click **Open Anyway** in System Settings → Privacy & Security.

To update, quit OpenGallery from its menu and replace the app. If you use
Force Click, allow OpenGallery again under Input Monitoring.

## Verify

GitHub built this zip from the tagged source and signed a record of it. To
check your download came from this repo's code:

\`\`\`bash
gh attestation verify OpenGallery-$VERSION.zip --repo isaaczaak/opengallery
\`\`\`
NOTES
