# Releasing DockState

Releases are built by [`.github/workflows/release.yml`](../.github/workflows/release.yml) and published as a
DMG on GitHub Releases.

```bash
git tag v1.0.0
git push origin v1.0.0
```

The workflow runs the tests, builds a universal (Apple Silicon + Intel) app, packages
`DockState-<version>.dmg` with a SHA-256 checksum, and creates the GitHub release with generated notes.

## Signing and notarization

Users get a Gatekeeper-clean install only if the app is signed with a **Developer ID Application**
certificate and **notarized** by Apple. That needs a paid Apple Developer Program membership.

| Secret | What it is |
| --- | --- |
| `DEVELOPER_ID_CERTIFICATE_P12` | Base64 of the exported "Developer ID Application" certificate + private key (`base64 -i cert.p12 \| pbcopy`) |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | Password used when exporting the `.p12` |
| `DEVELOPER_ID_APPLICATION` | Full identity name, e.g. `Developer ID Application: Jane Doe (ABCDE12345)` |
| `APPLE_TEAM_ID` | Your 10-character team ID |
| `NOTARY_KEY_P8` | Contents of an App Store Connect API key (`AuthKey_XXXX.p8`) with Developer access |
| `NOTARY_KEY_ID` | That key's ID |
| `NOTARY_ISSUER_ID` | The issuer ID shown on the App Store Connect "Keys" page |

**Without these secrets** the workflow still runs, but it publishes an ad-hoc signed DMG named
`DockState-<version>-unsigned.dmg` as a **pre-release** with a warning. Nothing claims to be signed when
it isn't.

## Building locally

```bash
scripts/build-release.sh 1.0.0          # dist/DockState.app (universal)
scripts/make-dmg.sh 1.0.0               # dist/DockState-1.0.0.dmg
```

Set `DEVELOPER_ID_APPLICATION` (and `APPLE_TEAM_ID`) to sign with your certificate, then
`scripts/notarize.sh dist/DockState-1.0.0.dmg` with either `NOTARY_KEY_PATH`/`NOTARY_KEY_ID`/`NOTARY_ISSUER_ID`
or `APPLE_ID`/`APPLE_APP_PASSWORD`/`APPLE_TEAM_ID`.

## Versioning

[Semantic versioning](https://semver.org). The version comes from the tag (`v1.2.3` → `1.2.3`); the
build number is the workflow run number. `Config/Version.xcconfig` holds the version used for local builds.

## Updates

DockState 1.0 makes **no network requests** at all, including update checks. Users update by
downloading a new DMG (or using "Watch → Releases" on GitHub). An opt-in updater (Sparkle 2 with
EdDSA-signed appcasts) is a candidate for a later version; it would remain off by default.
