#!/bin/bash
# Assembles VoxRouter.app from the SwiftPM binary.
#
# SwiftPM produces a bare executable, and macOS will not grant microphone access
# to one: TCC identifies apps by bundle id and code signature, so the daemon has
# to be a real .app bundle. Only Command Line Tools are installed here (no full
# Xcode), so the bundle is assembled by hand rather than by xcodebuild.
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/VoxRouter.app"
BUNDLE_ID="dev.voxrouter.app"

cd "$ROOT"
echo "Building ($CONFIG)…"
swift build -c "$CONFIG" --product VoxRouterApp

BIN="$(swift build -c "$CONFIG" --product VoxRouterApp --show-bin-path)/VoxRouterApp"
[ -x "$BIN" ] || { echo "error: binary not found at $BIN" >&2; exit 1; }

# Braced, because the ellipsis that follows is multibyte: `$APP…` is parsed as a
# single variable name under some locales and fails with `unbound variable`
# under `set -u`. It worked in a C-locale shell and broke in a UTF-8 one.
echo "Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/VoxRouter"

VERSION="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo dev)"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>VoxRouter</string>
  <key>CFBundleDisplayName</key><string>VoxRouter</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>VoxRouter</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <!-- Menu bar only: no Dock icon, no app menu. -->
  <key>LSUIElement</key><true/>
  <!-- Required, or the microphone prompt never appears and capture fails
       silently. -->
  <key>NSMicrophoneUsageDescription</key>
  <string>VoxRouter listens when you hold the push-to-talk key, so you can speak tasks to Claude Code and Codex.</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>VoxRouter transcribes what you say on-device to turn it into a task.</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Signing.
#
# With VOXROUTER_SIGN_IDENTITY set to a "Developer ID Application: …" identity,
# signs for distribution: hardened runtime (required by notarization) plus the
# microphone entitlement (required *because of* the hardened runtime — without
# it the app captures silence).
#
# Otherwise ad-hoc, which is fine locally: it gives TCC a stable identity so the
# microphone grant survives rebuilds. Ad-hoc builds cannot be notarized and will
# be blocked by Gatekeeper on anyone else's Mac.
ENTITLEMENTS="$ROOT/Scripts/VoxRouter.entitlements"

# Pick a stable identity if one exists.
#
# This is what stops macOS asking for the microphone after every rebuild. An
# ad-hoc signature's designated requirement is a raw cdhash:
#
#   designated => cdhash H"042935a1…"
#
# which changes with the binary, so TCC treats each build as a different app and
# re-prompts. Any real certificate — even a free self-signed one — produces a
# requirement based on the bundle id and the certificate instead, which survives
# rebuilds. See Scripts/RELEASING.md.
if [ -z "${VOXROUTER_SIGN_IDENTITY:-}" ]; then
  # Prefer Developer ID (also satisfies Gatekeeper), else a local cert.
  # `|| true` throughout: under `set -euo pipefail` a grep that matches nothing
  # returns 1 and takes the whole script down. Finding no certificate is the
  # normal case, not an error.
  identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  VOXROUTER_SIGN_IDENTITY="$(
    printf '%s\n' "$identities" \
      | grep -oE '"Developer ID Application: [^"]+"' | head -1 | tr -d '"' || true
  )"
  if [ -z "$VOXROUTER_SIGN_IDENTITY" ]; then
    VOXROUTER_SIGN_IDENTITY="$(
      printf '%s\n' "$identities" \
        | grep -oE '"VoxRouter Local[^"]*"' | head -1 | tr -d '"' || true
    )"
  fi

  # A self-signed certificate made in Certificate Assistant is not trusted for
  # code signing by default, so it exists but `codesign` won't use it. Without
  # this check the script silently falls back to ad-hoc and the microphone
  # prompt keeps returning, with nothing explaining why.
  if [ -z "$VOXROUTER_SIGN_IDENTITY" ]; then
    untrusted="$(
      security find-identity -p codesigning 2>/dev/null \
        | grep -E 'CSSMERR_TP_NOT_TRUSTED' | head -1 || true
    )"
    if [ -n "$untrusted" ]; then
      echo
      echo "  Found a code-signing certificate that isn't trusted yet:"
      echo "    ${untrusted#*\"}" | sed 's/".*//;s/^/    /'
      echo
      echo "  In Keychain Access: double-click it, expand Trust, set"
      echo "  'Code Signing' to 'Always Trust', then close the window."
      echo "  Until then this build is ad-hoc signed and macOS will keep"
      echo "  asking for the microphone after every rebuild."
      echo
    fi
  fi
fi

if [ -n "${VOXROUTER_SIGN_IDENTITY:-}" ]; then
  echo "Signing for distribution as: $VOXROUTER_SIGN_IDENTITY"
  codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$VOXROUTER_SIGN_IDENTITY" "$APP"
  codesign --verify --strict --verbose=1 "$APP"
else
  echo "Signing (ad-hoc)…"
  codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1
  echo
  echo "  Note: ad-hoc signing means macOS will ask for microphone access again"
  echo "  after every rebuild. A free self-signed certificate fixes that —"
  echo "  see Scripts/RELEASING.md → 'Stop the microphone prompt repeating'."
fi

echo "Built $APP"
echo
# Speech model assets are scoped to the requesting app's identity, so a model
# installed by the CLI does not count for the app. Doing it here means a fresh
# build is ready to use rather than silently stalling at first launch.
echo "Checking the speech model for ${BUNDLE_ID}…"
"$APP/Contents/MacOS/VoxRouter" --install-model || true
echo
echo "  open $APP"
echo
echo "If it misbehaves:  $APP/Contents/MacOS/VoxRouter --diagnose"
echo "To start at login: System Settings ▸ General ▸ Login Items ▸ + ▸ $APP"
