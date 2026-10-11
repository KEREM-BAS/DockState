# Security Policy

DockState runs locally and stores data only in `~/Library/Application Support/DockState/`. It uses the
Accessibility permission to read and set window positions and sizes. Its only network access is the update
check (Sparkle), which reads the appcast attached to this repository's latest release — once a day if the
user agreed to automatic checks, otherwise only on *Check Now*. Updates are verified with an EdDSA signature
(the public key is built into the app) and their code signature before they are installed.

If you find a security issue (for example a way to misuse DockState's Accessibility access, or a problem in
the release/signing pipeline), please report it privately via
[GitHub Security Advisories](https://github.com/KEREM-BAS/DockState/security/advisories/new) rather than a
public issue. You'll get a response as soon as possible.

Only the latest release receives fixes.
