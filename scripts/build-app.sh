#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
signing_identity="${VELINSHOT_SIGNING_IDENTITY-}"
if [ "${VELINSHOT_SIGNING_IDENTITY+x}" = x ]; then
  case "$signing_identity" in
    "Developer ID Application:"*) ;;
    *) printf 'VELINSHOT_SIGNING_IDENTITY must name a Developer ID Application certificate.\n' >&2; exit 2 ;;
  esac
  if ! security find-identity -v -p codesigning | grep -F -- "\"$signing_identity\"" >/dev/null; then
    printf 'The requested Developer ID Application identity is not available in this keychain.\n' >&2
    exit 2
  fi
fi
swift build -c release -j 2
binary_dir="$(swift build -c release --show-bin-path)"
bundle_path="${1:-build/Velinshot.app}"
mkdir -p "$bundle_path/Contents/MacOS" "$bundle_path/Contents/Resources"
cp "$binary_dir/Velinshot" "$bundle_path/Contents/MacOS/Velinshot"
if [ -f Resources/AppIcon.png ]; then
  iconset_dir="build/Velinshot.iconset"
  mkdir -p "$iconset_dir"
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Resources/AppIcon.png --out "$iconset_dir/icon_${size}x${size}.png" >/dev/null
    retina_size=$((size * 2))
    sips -z "$retina_size" "$retina_size" Resources/AppIcon.png --out "$iconset_dir/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$iconset_dir" --output "$bundle_path/Contents/Resources/AppIcon.icns"
fi
cp Resources/Info.plist "$bundle_path/Contents/Info.plist"
python3 - "$bundle_path/Contents/Resources/BuildInfo.json" <<'PY'
import json, plistlib, subprocess, sys
from pathlib import Path

def git(*arguments):
    result = subprocess.run(['git', *arguments], capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 else None

info = plistlib.loads(Path('Resources/Info.plist').read_bytes())
revision = git('rev-parse', 'HEAD')
status = git('status', '--porcelain', '--untracked-files=normal')
metadata = {'sourceRevision': revision, 'sourceDirty': None if status is None else bool(status),
            'version': info['CFBundleShortVersionString'], 'build': info['CFBundleVersion']}
Path(sys.argv[1]).write_text(json.dumps(metadata, indent=2, sort_keys=True) + '\n')
PY
if [ "${VELINSHOT_SIGNING_IDENTITY+x}" = x ]; then
  codesign --force --sign "$signing_identity" --options runtime --timestamp "$bundle_path"
else
  codesign --force --sign - "$bundle_path"
fi
codesign --verify --deep --strict "$bundle_path"
plutil -lint "$bundle_path/Contents/Info.plist"
du -sh "$bundle_path"
printf 'Built %s\n' "$bundle_path"
