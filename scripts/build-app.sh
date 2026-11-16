#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
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
codesign --force --sign - "$bundle_path"
codesign --verify --deep --strict "$bundle_path"
plutil -lint "$bundle_path/Contents/Info.plist"
du -sh "$bundle_path"
printf 'Built %s\n' "$bundle_path"
