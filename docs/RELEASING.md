# Releasing DockState

Releases are built by [`.github/workflows/release.yml`](../.github/workflows/release.yml) and published as a
DMG on GitHub Releases.

```bash
git tag v1.0.0
git push origin v1.0.0
```

The workflow runs the tests, builds a universal (Apple Silicon + Intel) app, signs and notarizes it,
packages `DockState-<version>.dmg` with a SHA-256 checksum, signs the DMG for in-app updates and writes
`appcast.xml`, and creates the GitHub release with generated notes and all three files. Versions with a
suffix (`v1.1.0-beta.1`) are published as pre-releases.

## Why signing matters

DockState is meant to be downloaded from GitHub. For that to be pleasant and safe:

- **Gatekeeper** only opens a downloaded app without warnings when it is signed with a *Developer ID* and
  **notarized** by Apple. Unsigned builds need a trip to System Settings › Privacy & Security › *Open Anyway*.
- **The Accessibility permission is tied to the signature.** With a stable Developer ID signature, updates keep
  the permission. Ad-hoc (unsigned) builds have a different signature every version, so users must turn the
  permission off and on again after each update.
- **In-app updates need the update signing key.** Sparkle installs an update only if its EdDSA signature
  matches the public key built into the installed app (`SUPublicEDKey` in `Config/Info.plist`). **If the
  private key is lost, installed copies can't be updated from inside the app any more** — users would have to
  download a new version by hand. Keep a backup.

Both need a paid Apple Developer Program membership. Without the secrets below the workflow still runs and
publishes `DockState-<version>-unsigned.dmg` as a **pre-release** with instructions. Nothing claims to be
signed when it isn't.

## One-time setup (Apple Developer account holder)

### 1. Create a Developer ID Application certificate

1. On the Mac, open **Keychain Access** › *Keychain Access* menu › *Certificate Assistant* ›
   **Request a Certificate From a Certificate Authority…**. Enter your email, choose *Saved to disk*, save the
   `.certSigningRequest` file.
2. Go to <https://developer.apple.com/account/resources/certificates/add>, choose **Developer ID Application**
   (not "Apple Development" or "Apple Distribution"), upload the request, download the `.cer` file and
   double-click it to add it to your keychain.
3. Check it's there:

   ```bash
   security find-identity -v -p codesigning | grep "Developer ID Application"
   ```

   Copy the full name in quotes, e.g. `Developer ID Application: Kerem Baş (6X2P9AVK3T)`.

### 2. Export it as a .p12

In Keychain Access › *My Certificates*, right-click the **Developer ID Application** certificate (with its private
key) › **Export…** › format *Personal Information Exchange (.p12)*, choose a strong password. Then:

```bash
base64 -i DeveloperID.p12 | pbcopy
```

### 3. Create an App Store Connect API key for notarization

<https://appstoreconnect.apple.com/access/integrations/api> › *Team Keys* › **+** › name "DockState notarization",
access **Developer**. Download `AuthKey_XXXXXXXXXX.p8` (only possible once) and note the **Key ID** and the
**Issuer ID** shown above the list.

### 4. Create the update signing key (Sparkle)

Build once so Xcode fetches Sparkle (`scripts/build-release.sh`), then:

```bash
build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account dockstate
build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account dockstate -x sparkle_private.key
```

The first command stores the private key in your login keychain and prints the public key: put it in
`Config/Info.plist` as `SUPublicEDKey` (DockState's is already there; a new key only makes sense for a fork).
The second exports the private key — back it up somewhere safe (a password manager) and keep it out of the
repository (`.gitignore` ignores `*.key`).

### 5. Add the GitHub secrets

Repository › *Settings* › *Secrets and variables* › *Actions* › **New repository secret**:

| Secret | Value |
| --- | --- |
| `DEVELOPER_ID_CERTIFICATE_P12` | the base64 text from step 2 |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | the .p12 password |
| `DEVELOPER_ID_APPLICATION` | the full identity name from step 1 |
| `APPLE_TEAM_ID` | your 10-character team ID (in parentheses in the identity name) |
| `NOTARY_KEY_P8` | the full contents of `AuthKey_XXXXXXXXXX.p8`, including the BEGIN/END lines |
| `NOTARY_KEY_ID` | the key ID |
| `NOTARY_ISSUER_ID` | the issuer ID |
| `SPARKLE_ED_PRIVATE_KEY` | the exported Sparkle private key from step 4 (`gh secret set SPARKLE_ED_PRIVATE_KEY < sparkle_private.key`) |

Signing is used only when **all eight** are set. If only some of them are set, the release fails instead of quietly publishing an unsigned build (or a signed one without the appcast, which would stop in-app updates).

Set secrets from files with `gh secret set NAME < file` rather than in the web form: the form never shows the
current value, so it's easy to overwrite a secret with an empty or truncated one.

### 6. Release

```bash
git tag v0.2.0 && git push origin v0.2.0
```

Watch *Actions › Release*. The log line `Building DockState 0.2.0 (signed: true)` confirms the signed path.
Notarization usually takes a few minutes. Afterwards the feed the app reads should name the new version:

```bash
curl -sL https://github.com/KEREM-BAS/DockState/releases/latest/download/appcast.xml | grep shortVersionString
```

To try the whole pipeline without publishing, run the workflow by hand (*Actions › Release › Run workflow*,
or `gh workflow run release.yml --ref <branch> -f version=0.2.0-rc.1`): it creates a **draft** pre-release
that only collaborators see. Delete it afterwards.

## Building locally

```bash
scripts/build-release.sh 1.0.0          # dist/DockState.app (universal)
scripts/make-dmg.sh 1.0.0               # dist/DockState-1.0.0.dmg + .sha256
```

To sign locally, set `DEVELOPER_ID_APPLICATION` (and `APPLE_TEAM_ID`) before both commands, then:

```bash
scripts/notarize.sh app                          # notarize + staple the app
scripts/make-dmg.sh 1.0.0                        # package the stapled app
scripts/notarize.sh dist/DockState-1.0.0.dmg     # notarize + staple the DMG
SPARKLE_KEY_FILE=sparkle_private.key scripts/make-appcast.sh 1.0.0 dist/DockState-1.0.0.dmg   # dist/appcast.xml
```

A signed build needs `BUILD_NUMBER` set higher than the last release's (Sparkle orders updates by build number).
`make-appcast.sh` checks the DMG's signature against `SUPublicEDKey` in the app and, with `MIN_BUILD`, that the
build number is higher than the published one; the release workflow passes the published one.

`build-release.sh` removes Sparkle's XPC services (only sandboxed apps need them) and signs Sparkle's helpers
inside out before re-signing the app; notarization rejects them otherwise. It always signs with the hardened
runtime. Ad-hoc builds have no team ID, so they also get `Config/AdHoc.entitlements` (library validation off,
so Sparkle.framework loads); Developer ID builds don't.

Forks: `SUFeedURL` and `SUPublicEDKey` in `Config/Info.plist` point at this repository's releases and key.
Change both (and create your own key, step 4) before publishing builds of a fork. `scripts/test-update.sh`
tests the update path end to end without publishing anything (see [TESTING.md](TESTING.md)).

with either `NOTARY_KEY_PATH`/`NOTARY_KEY_ID`/`NOTARY_ISSUER_ID` or `APPLE_ID`/`APPLE_APP_PASSWORD`/`APPLE_TEAM_ID`.

## Versioning

[Semantic versioning](https://semver.org). The version comes from the tag (`v1.2.3` → `1.2.3`); the build
number is the workflow run number. `Config/Version.xcconfig` holds the version used for local builds.
Sparkle compares build numbers, so they must only grow: don't rename `release.yml` (that restarts the run
number at 1).

## Updates

The app reads `https://github.com/KEREM-BAS/DockState/releases/latest/download/appcast.xml` — the appcast
attached to the latest stable release (drafts and pre-releases are never "latest"). Each signed release
attaches its own `appcast.xml` with one item: version, build number, minimum macOS, the generated release
notes and the DMG's EdDSA signature. It's created in the same step as the release, so the latest release never
lacks it. Only a version newer than the current latest release becomes "latest" (a hotfix for an older line is
published with `--latest=false`), and its build number must be higher than the published one. Nothing is requested before the user agrees to automatic checks or presses *Check Now* (see
[BEHAVIOR.md](BEHAVIOR.md#updates)).
