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

echo "Assembling $APP…"
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
if [ -n "${VOXROUTER_SIGN_IDENTITY:-}" ]; then
  echo "Signing for distribution as: $VOXROUTER_SIGN_IDENTITY"
  codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$VOXROUTER_SIGN_IDENTITY" "$APP"
  codesign --verify --strict --verbose=1 "$APP"
else
  echo "Signing (ad-hoc — local use only, Gatekeeper will block this elsewhere)…"
  codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1
fi

echo "Built $APP"
echo
# Speech model assets are scoped to the requesting app's identity, so a model
# installed by the CLI does not count for the app. Doing it here means a fresh
# build is ready to use rather than silently stalling at first launch.
echo "Checking the speech model for $BUNDLE_ID…"
"$APP/Contents/MacOS/VoxRouter" --install-model || true
echo
echo "  open $APP"
echo
echo "If it misbehaves:  $APP/Contents/MacOS/VoxRouter --diagnose"
echo "To start at login: System Settings ▸ General ▸ Login Items ▸ + ▸ $APP"
