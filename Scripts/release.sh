#!/bin/bash
# Builds VoxRouter.app and zips it for a GitHub release.
#
# The archive is made with `ditto --keepParent`, not `zip`: plain zip mangles
# extended attributes and the code signature, and the app then refuses to launch
# on the machine that downloads it.
set -euo pipefail

VERSION="${1:-}"
[ -n "$VERSION" ] || { echo "usage: $0 <version>   e.g. $0 0.1.0" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/VoxRouter.app"
DIST="$ROOT/build/dist"
ARCHIVE="$DIST/VoxRouter-$VERSION-macos-arm64.zip"

"$ROOT/Scripts/build-app.sh" release

mkdir -p "$DIST"
rm -f "$ARCHIVE"
ditto -c -k --keepParent --sequesterRsrc "$APP" "$ARCHIVE"

echo
echo "Archive: $ARCHIVE"
echo "Size:    $(du -h "$ARCHIVE" | cut -f1)"
echo "SHA-256: $(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1)"
