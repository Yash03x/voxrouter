# Releasing

## Stop the microphone prompt repeating

If macOS asks for microphone access every time you rebuild, this is why.

TCC identifies an app by its code signature. An ad-hoc signature's designated
requirement is a raw hash of the binary:

```bash
codesign -d -r- build/VoxRouter.app
# designated => cdhash H"042935a100268e9f58ce544ca71d383ac4760bcc"
```

Change one byte of code and that hash changes, so macOS concludes it has never
seen this app before and asks again. Rebuild ten times, get asked ten times.

**A free self-signed certificate fixes it.** Any real certificate produces a
requirement based on the bundle id and the certificate rather than the binary
hash, and the grant then survives rebuilds.

Create one once, in Keychain Access:

1. **Keychain Access** ▸ menu **Certificate Assistant** ▸ **Create a
   Certificate…**
2. Name: **`VoxRouter Local`** (the build script looks for this name)
3. Identity Type: **Self Signed Root**
4. Certificate Type: **Code Signing**
5. Create, then Done.

6. **Then trust it for code signing** — this step is easy to miss and the
   certificate is useless without it. Double-click **VoxRouter Local**, expand
   **Trust**, set **Code Signing** to **Always Trust**, and close the window
   (macOS asks for your password).

Without step 6 the certificate exists but `codesign` refuses it:

```bash
security find-identity -v -p codesigning
#      0 valid identities found          ← not usable

security find-identity -p codesigning
#   1) BA15A477… "VoxRouter Local" (CSSMERR_TP_NOT_TRUSTED)
```

`build-app.sh` detects exactly this and says so, rather than quietly falling
back to ad-hoc.

Once trusted, `./Scripts/build-app.sh` finds it automatically, and the
microphone prompt appears once and stays answered.

To confirm it took:

```bash
codesign -d -r- build/VoxRouter.app
# designated => identifier "dev.voxrouter.app" and certificate leaf = H"…"
#                ^ stable across rebuilds, unlike a bare cdhash
```

A self-signed certificate does **not** satisfy Gatekeeper — it only fixes the
repeated prompt on your own machine. For distributing to other people you need a
Developer ID, below.


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
