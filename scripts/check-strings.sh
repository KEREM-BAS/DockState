#!/bin/bash
# CI check for DockState/Localizable.xcstrings.
#
# Fails when the catalog is out of sync with the code (a string was added or removed
# without running scripts/sync-strings.sh). Missing translations only produce warnings, so
# contributors who don't speak a language aren't blocked. Formatting differences between
# Xcode versions are ignored: the JSON content is compared, not the text.
set -euo pipefail
cd "$(dirname "$0")/.."
CATALOG=DockState/Localizable.xcstrings
BEFORE="$(mktemp)"
cp "$CATALOG" "$BEFORE"
# Always put the developer's catalog back, even if syncing fails or is interrupted.
trap 'cp "$BEFORE" "$CATALOG"; rm -f "$BEFORE"' EXIT
scripts/sync-strings.sh >/dev/null
STATUS=0
python3 - "$BEFORE" "$CATALOG" <<'PY' || STATUS=$?
import json, sys
before, after = (json.load(open(p)) for p in sys.argv[1:3])
def live(d):
    return {k for k, v in d["strings"].items() if v.get("extractionState") != "stale"}
added = sorted(live(after) - live(before))
removed = sorted(set(before["strings"]) - set(after["strings"]))
stale = sorted(k for k, v in after["strings"].items() if v.get("extractionState") == "stale")
problems = False
if added:
    problems = True
    print("::error::New strings are missing from Localizable.xcstrings — run scripts/sync-strings.sh:")
    for k in added: print("   +", k)
if removed:
    problems = True
    print("::error::Strings no longer used by the code are still in Localizable.xcstrings — run scripts/sync-strings.sh:")
    for k in removed: print("   -", k)
if stale:
    problems = True
    print("::error::Strings no longer used by the code are still in Localizable.xcstrings — run scripts/sync-strings.sh and remove them:")
    for k in stale: print("   -", k)
languages = {"tr"}
for key, entry in after["strings"].items():
    if not key or entry.get("shouldTranslate") is False or entry.get("extractionState") == "stale":
        continue
    missing = [l for l in sorted(languages) if l not in entry.get("localizations", {})]
    if missing:
        print(f"::warning::Missing {', '.join(missing)} translation: {key}")
sys.exit(1 if problems else 0)
PY
exit $STATUS
