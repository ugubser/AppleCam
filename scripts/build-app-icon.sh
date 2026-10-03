#!/bin/bash
# Package the approved artwork into macOS icon sizes without redesigning it.
set -euo pipefail
cd "$(dirname "$0")/.."
source_image="artifacts/branding/applecam-logo-concept-01.png"
iconset="work/AppIcon.iconset"
mkdir -p "$iconset" AppleCam/Resources
for points in 16 32 128 256 512; do
  /usr/bin/sips -z "$points" "$points" "$source_image" --out "$iconset/icon_${points}x${points}.png" >/dev/null
  pixels=$((points * 2))
  /usr/bin/sips -z "$pixels" "$pixels" "$source_image" --out "$iconset/icon_${points}x${points}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "$iconset" -o AppleCam/Resources/AppIcon.icns
