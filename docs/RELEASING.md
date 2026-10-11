# Releasing DockState

Releases are built by [`.github/workflows/release.yml`](../.github/workflows/release.yml) and published as a
DMG on GitHub Releases.

```bash
git tag v1.0.0
git push origin v1.0.0
```

The workflow runs the tests, builds a universal (Apple Silicon + Intel) app, signs and notarizes it,
packages `DockState-<version>.dmg` with a SHA-256 checksum, and creates the GitHub release with generated
notes. Versions with a suffix (`v1.1.0-beta.1`) are published as pre-releases.

## Why signing matters

DockState is meant to be downloaded from GitHub. For that to be pleasant and safe:

- **Gatekeeper** only opens a downloaded app without warnings when it is signed with a *Developer ID* and
  **notarized** by Apple. Unsigned builds need a trip to System Settings › Privacy & Security › *Open Anyway*.
- **The Accessibility permission is tied to the signature.** With a stable Developer ID signature, updates keep
  the permission. Ad-hoc (unsigned) builds have a different signature every version, so users must turn the
  permission off and on again after each update.

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

### 4. Add the GitHub secrets

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

Signing is used only when **all seven** are set. If only some of them are set, the release fails instead of quietly publishing an unsigned build.

### 5. Release

```bash
git tag v0.2.0 && git push origin v0.2.0
```

Watch *Actions › Release*. The log line `Building DockState 0.2.0 (signed: true)` confirms the signed path.
Notarization usually takes a few minutes.

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
```

with either `NOTARY_KEY_PATH`/`NOTARY_KEY_ID`/`NOTARY_ISSUER_ID` or `APPLE_ID`/`APPLE_APP_PASSWORD`/`APPLE_TEAM_ID`.

## Versioning

[Semantic versioning](https://semver.org). The version comes from the tag (`v1.2.3` → `1.2.3`); the build
number is the workflow run number. `Config/Version.xcconfig` holds the version used for local builds.

## Updates

DockState makes no network requests unless the user turns on **Settings › General › Check for updates
automatically** (or presses *Check Now*). It then reads this repository's public releases feed
(`https://github.com/KEREM-BAS/DockState/releases.atom`) at most once a day and links to the release page. Nothing
is downloaded or installed automatically.
