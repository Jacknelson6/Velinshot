#!/bin/bash
# Install a verified bundle without replacing a running app or deleting its predecessor.
set -euo pipefail
cd "$(dirname "$0")/.."
source_path="${1:-build/Velinshot.app}"
destination="${2:-/Applications/Velinshot.app}"
source_path="$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).resolve())' "$source_path")"
destination="$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).resolve())' "$destination")"
if [ "$(basename "$destination")" != Velinshot.app ] || [ "$source_path" = "$destination" ]; then
  printf 'Choose a separate destination named Velinshot.app.\n' >&2; exit 2
fi
python3 - "$source_path" "$destination" <<'PY'
from pathlib import Path
import sys
source, destination = map(Path, sys.argv[1:])
if source in destination.parents or destination in source.parents:
    raise SystemExit('Source and destination must not contain one another.')
PY
python3 scripts/verify-bundle.py "$source_path"
if pgrep -x Velinshot >/dev/null; then
  printf 'Quit Velinshot before installing, after saving any work you want to keep.\n' >&2; exit 2
fi
parent="$(dirname "$destination")"
mkdir -p "$parent"
lock="$parent/.Velinshot-install.lock"
if ! mkdir "$lock" 2>/dev/null; then
  printf 'Another install may be in progress: %s\n' "$lock" >&2; exit 2
fi
staging=""
backup=""
installed=0
complete=0
finish() {
  result=$?
  if [ "$installed" = 1 ] && [ "$complete" != 1 ]; then
    if [ -d "$destination" ]; then mv "$destination" "$staging/rejected.app"; fi
    if [ -n "$backup" ] && [ -d "$backup" ]; then mv "$backup" "$destination"; fi
  elif [ "$complete" != 1 ] && [ -n "$backup" ] && [ -d "$backup" ] && [ ! -e "$destination" ]; then
    mv "$backup" "$destination"
  fi
  if [ -n "$staging" ] && [ -d "$staging" ]; then rm -rf "$staging"; fi
  rmdir "$lock"
  exit "$result"
}
trap finish EXIT
staging="$(mktemp -d "$parent/.Velinshot-install.XXXXXX")"
ditto "$source_path" "$staging/Velinshot.app"
python3 scripts/verify-bundle.py "$staging/Velinshot.app"
if pgrep -x Velinshot >/dev/null; then
  printf 'Velinshot opened during installation. Quit it and try again.\n' >&2; exit 2
fi
if [ -e "$destination" ]; then
  python3 - "$destination" <<'PY'
import plistlib, sys
from pathlib import Path
info = plistlib.loads((Path(sys.argv[1]) / 'Contents/Info.plist').read_bytes())
if info.get('CFBundleIdentifier') != 'com.jacknelson.velinshot':
    raise SystemExit('The destination belongs to another app; nothing was replaced.')
PY
  backup_dir="$parent/.Velinshot Backups"
  mkdir -p "$backup_dir"
  backup="$backup_dir/Velinshot-$(date -u +%Y%m%dT%H%M%SZ)-$$.app"
  mv "$destination" "$backup"
fi
mv "$staging/Velinshot.app" "$destination"
installed=1
python3 scripts/verify-bundle.py "$destination"
python3 - "$source_path" "$destination" <<'PY'
import hashlib, sys
from pathlib import Path
def digest(bundle):
    return hashlib.sha256((Path(bundle) / 'Contents/MacOS/Velinshot').read_bytes()).hexdigest()
expected, actual = map(digest, sys.argv[1:])
if expected != actual:
    raise SystemExit('Installed executable does not match the source; restoring the previous app.')
print('Installed executable SHA-256:', actual)
PY
complete=1
printf 'Installed %s\n' "$destination"
if [ -n "$backup" ]; then printf 'Previous app preserved at %s\n' "$backup"; fi
printf 'Open it with: open %q\n' "$destination"
