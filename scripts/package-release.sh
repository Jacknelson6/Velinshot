#!/bin/bash
# Package an already checked app built from this clean source revision.
set -euo pipefail
cd "$(dirname "$0")/.."
bundle_path="${1:-build/Velinshot.app}"
output="${2:-build/release}"
python3 scripts/verify-bundle.py "$bundle_path" --require-updater
python3 - "$bundle_path" <<'PY'
import json, subprocess, sys
from pathlib import Path
revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
status = subprocess.check_output(['git', 'status', '--porcelain', '--untracked-files=normal'], text=True).strip()
if status:
    raise SystemExit('Commit the release source before packaging.')
metadata = json.loads((Path(sys.argv[1]) / 'Contents/Resources/BuildInfo.json').read_text())
if metadata.get('sourceRevision') != revision or metadata.get('sourceDirty') is not False:
    raise SystemExit('Rebuild the app from the current clean commit before packaging.')
PY
architecture="$(lipo -archs "$bundle_path/Contents/MacOS/Velinshot")"
case "$architecture" in
  arm64|x86_64) ;;
  "x86_64 arm64"|"arm64 x86_64") architecture=universal ;;
  *) printf 'Unsupported release architecture: %s\n' "$architecture" >&2; exit 2 ;;
esac
mkdir -p "$output"
archive_name="Velinshot-preview-$architecture"
ditto -c -k --sequesterRsrc --keepParent "$bundle_path" "$output/$archive_name.zip"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/velinshot-package.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
ditto "$bundle_path" "$scratch/Velinshot.app"
ln -s /Applications "$scratch/Applications"
hdiutil create -volname Velinshot -srcfolder "$scratch" -format UDZO -ov "$output/$archive_name.dmg" >/dev/null
python3 - "$bundle_path" "$output" "$architecture" "$archive_name" <<'PY'
import hashlib, json, plistlib, subprocess, sys
from datetime import datetime, timezone
from pathlib import Path
bundle, output = map(Path, sys.argv[1:3])
architecture, name = sys.argv[3:5]
info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
build = json.loads((bundle / 'Contents/Resources/BuildInfo.json').read_text())
signature = subprocess.run(['codesign', '--display', '--verbose=4', str(bundle)], check=True, capture_output=True, text=True).stderr
developer_id = 'Authority=Developer ID Application:' in signature
signing_kind = 'developer-id' if developer_id else ('ad-hoc' if 'Signature=adhoc' in signature else 'other')
notarized = developer_id and subprocess.run(['xcrun', 'stapler', 'validate', str(bundle)], capture_output=True).returncode == 0
def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()
files = [output / (name + suffix) for suffix in ('.zip', '.dmg')]
metadata = {**build, 'bundleIdentifier': info['CFBundleIdentifier'], 'architecture': architecture,
            'packagedAt': datetime.now(timezone.utc).isoformat(),
            'binarySHA256': digest(bundle / 'Contents/MacOS/Velinshot'),
            'signing': signing_kind, 'notarized': notarized,
            'archives': {path.name: digest(path) for path in files}}
(output / 'BUILD-INFO.json').write_text(json.dumps(metadata, indent=2, sort_keys=True) + '\n')
files.append(output / 'BUILD-INFO.json')
(output / 'SHA256SUMS.txt').write_text(''.join(f'{digest(path)}  {path.name}\n' for path in files))
print('Packaged', ', '.join(path.name for path in files))
print('Signing:', metadata['signing'], '| Notarized:', notarized)
PY
