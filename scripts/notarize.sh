#!/bin/bash
# Credentials must already exist in the caller's notarytool keychain profile.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "$#" -ne 2 ]; then
  printf 'Usage: bash scripts/notarize.sh <Velinshot.app> <keychain-profile>\n' >&2; exit 2
fi
bundle_path="$1"
profile="$2"
if [ -z "$profile" ]; then printf 'An existing notarytool keychain profile is required.\n' >&2; exit 2; fi
python3 scripts/verify-bundle.py "$bundle_path" --require-developer-id
xcrun --find notarytool >/dev/null
xcrun --find stapler >/dev/null
scratch="$(mktemp -d "${TMPDIR:-/tmp}/velinshot-notary.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
ditto -c -k --sequesterRsrc --keepParent "$bundle_path" "$scratch/Velinshot.zip"
xcrun notarytool submit "$scratch/Velinshot.zip" --keychain-profile "$profile" --wait --timeout 15m --output-format json > "$scratch/result.json"
python3 - "$scratch/result.json" <<'PY'
import json, sys
from pathlib import Path
result = json.loads(Path(sys.argv[1]).read_text())
if result.get('status') != 'Accepted':
    raise SystemExit('Apple did not accept this submission. Inspect it with notarytool log using submission ID: ' + str(result.get('id', 'unknown')))
print('Apple accepted submission:', result.get('id'))
PY
xcrun stapler staple "$bundle_path"
python3 scripts/verify-bundle.py "$bundle_path" --require-notarized
printf 'Apple notarization, stapled ticket and Gatekeeper assessment passed for %s\n' "$bundle_path"
