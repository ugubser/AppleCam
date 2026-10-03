#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p work
swift test > work/tests.log 2>&1
xcodebuild -project AppleCam.xcodeproj -scheme AppleCam -configuration Debug \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build > work/build.log 2>&1
python3 - <<'PY'
from pathlib import Path
import plistlib
root = Path('build/DerivedData/Build/Products/Debug/AppleCam.app')
ext = root / 'Contents/Library/SystemExtensions/com.vanguardsignals.AppleCam.CameraExtension.systemextension'
for bundle, expected in [(root, 'com.vanguardsignals.AppleCam'), (ext, 'com.vanguardsignals.AppleCam.CameraExtension')]:
    info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
    assert info['CFBundleIdentifier'] == expected, (bundle, info['CFBundleIdentifier'])
    assert (bundle / 'Contents/MacOS' / info['CFBundleExecutable']).is_file(), bundle
assert plistlib.loads((ext / 'Contents/Info.plist').read_bytes())['CFBundlePackageType'] == 'SYSX'
print('Tests, unsigned Debug build, and embedded bundle layout passed.')
print('Logs: work/tests.log and work/build.log')
print('This does not verify signing, camera extension activation, or Teams delivery.')
PY
