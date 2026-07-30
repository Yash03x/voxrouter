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
# Version-free name on purpose: the README links to
# releases/latest/download/<name>, which only resolves if the asset name is
# stable across releases.
ARCHIVE="$DIST/VoxRouter-macos-arm64.zip"

"$ROOT/Scripts/build-app.sh" release

# A locally-created self-signed certificate is fine for stopping the microphone
# prompt on your own machine, but it means nothing to anyone downloading this —
# Gatekeeper rejects it exactly as it rejects an ad-hoc signature. Say so, or a
# release looks signed when it isn't usefully signed.
if codesign -dvvv "$APP" 2>&1 | grep -q 'Authority=VoxRouter Local'; then
  echo
  echo "  NOTE: signed with the local development certificate."
  echo "  Downloaders will still see a Gatekeeper warning. Only a Developer ID"
  echo "  removes it — see Scripts/RELEASING.md."
fi

mkdir -p "$DIST"
rm -f "$ARCHIVE"
ditto -c -k --keepParent --sequesterRsrc "$APP" "$ARCHIVE"

# Notarization, when credentials are configured.
#
# VOXROUTER_NOTARY_PROFILE names a keychain profile you create once with:
#   xcrun notarytool store-credentials <name> --apple-id … --team-id …
# Credentials live in your keychain and never appear here or in the repo.
#
# The order matters: notarize the archive, staple the ticket to the .app, then
# re-archive. Stapling embeds the ticket so the app validates offline; skip it
# and a machine without a network connection still shows a warning.
if [ -n "${VOXROUTER_NOTARY_PROFILE:-}" ]; then
  echo
  echo "Notarizing (this usually takes a few minutes)…"
  xcrun notarytool submit "$ARCHIVE" \
    --keychain-profile "$VOXROUTER_NOTARY_PROFILE" --wait

  echo "Stapling…"
  xcrun stapler staple "$APP"

  rm -f "$ARCHIVE"
  ditto -c -k --keepParent --sequesterRsrc "$APP" "$ARCHIVE"

  echo "Verifying as Gatekeeper would…"
  spctl -a -vvv -t install "$APP" || {
    echo "error: Gatekeeper still rejects the app" >&2
    exit 1
  }
else
  echo
  echo "NOTE: not notarized (VOXROUTER_NOTARY_PROFILE unset)."
  echo "      Gatekeeper will block this on other people's Macs."
fi

echo
echo "Archive: $ARCHIVE"
echo "Size:    $(du -h "$ARCHIVE" | cut -f1)"
echo "SHA-256: $(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1)"
