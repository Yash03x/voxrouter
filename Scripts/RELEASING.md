# Releasing

## Why the current release shows a warning

`VoxRouter.app` is **ad-hoc signed**. macOS attaches a quarantine flag to
anything downloaded from the internet, and Gatekeeper refuses to open a
quarantined app that isn't signed by a known developer *and* notarized by Apple.
Users can work around it (`xattr -dr com.apple.quarantine`), but most won't, and
asking them to is a bad look for a tool that runs shell commands.

A build made locally is never quarantined, which is why
`./Scripts/build-app.sh` works fine on your own machine and the same bundle
fails on someone else's.

## What a clean release needs

Three things, in order. The tooling for all of it is already in `build-app.sh`
and `release.sh` — only the certificate is missing.

### 1. Apple Developer Program — $99/year

Enrol at <https://developer.apple.com/programs/>. Individual membership is
enough; you don't need an organisation.

Then create a **Developer ID Application** certificate (Certificates ▸ + ▸
Developer ID Application) and download and double-click it to add it to your
keychain. Confirm it's there:

```bash
security find-identity -v -p codesigning
# 1) ABC123…  "Developer ID Application: Your Name (TEAMID)"
```

> Note this is *Developer ID Application*, not "Mac App Store" or "Apple
> Development". Only Developer ID works for distributing outside the App Store.

### 2. Sign with the hardened runtime

Notarization requires the hardened runtime, and the hardened runtime blocks
microphone access unless the entitlement is granted explicitly — that's what
`Scripts/VoxRouter.entitlements` is for. Miss it and you get an app that is
signed, notarized, and records silence.

```bash
export VOXROUTER_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
./Scripts/build-app.sh release
```

### 3. Notarize and staple

Store credentials once. Use an **app-specific password** from
<https://appleid.apple.com> — never your Apple ID password. It goes into your
keychain, not into this repo:

```bash
xcrun notarytool store-credentials voxrouter-notary \
  --apple-id you@example.com --team-id TEAMID
```

Then a release is one command:

```bash
export VOXROUTER_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export VOXROUTER_NOTARY_PROFILE=voxrouter-notary
./Scripts/release.sh 0.2.0
```

That signs, archives, submits to Apple, waits for the verdict, staples the
ticket to the bundle, re-archives, and verifies with `spctl` exactly as
Gatekeeper will. Stapling matters: without it the app needs a network round trip
to Apple on first launch, so an offline machine still shows a warning.

Publish it:

```bash
gh release create v0.2.0 build/dist/VoxRouter-0.2.0-macos-arm64.zip \
  --title "VoxRouter 0.2.0" --notes "…"
```

## Verifying it actually worked

Don't trust the build output — check the way a user's Mac will:

```bash
spctl -a -vvv -t install build/VoxRouter.app
# …: accepted
# source=Notarized Developer ID

xcrun stapler validate build/VoxRouter.app
# The validate action worked!
```

Better still, download your own release on a Mac that has never seen the app,
and open it by double-clicking.

## If you'd rather not pay

Reasonable for a young project. The honest alternatives:

- **Tell people to build from source.** `./Scripts/build-app.sh` takes about 30
  seconds and produces an unquarantined app. This is what the README leads with.
- **Homebrew cask.** Still quarantined for an unsigned app unless the user
  passes `--no-quarantine`, so it doesn't actually solve the warning — it just
  moves it.
- **Keep documenting the `xattr` step.** Works, but you're asking strangers to
  disable a security check to run software that executes shell commands on their
  machine. Fine among people who read the source; not fine at scale.

There is no free path to a warning-free download. Apple's signature is the only
thing Gatekeeper accepts, and it costs $99/year.
