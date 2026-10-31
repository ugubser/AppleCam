#!/bin/bash
# Native check of the local preview path: composed 4K60 frames into AVSampleBufferDisplayLayer in a real AppKit window.
set -euo pipefail
cd "$(dirname "$0")/.."
app=work/PreviewDisplayHarness.app; executable=$app/Contents/MacOS/PreviewDisplayHarness
rm -rf "$app"; mkdir -p "$(dirname "$executable")"
/usr/bin/plutil -create xml1 "$app/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleIdentifier -string com.vanguardsignals.AppleCam.PreviewDisplayHarness "$app/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleExecutable -string PreviewDisplayHarness "$app/Contents/Info.plist"
/usr/bin/plutil -insert CFBundlePackageType -string APPL "$app/Contents/Info.plist"
swiftc -parse-as-library -target arm64-apple-macos15.2 Shared/*.swift AppleCam/Capture/*.swift AppleCam/Transport/SinkTransport.swift \
  AppleCam/Processing/*.swift AppleCam/Scenes/SceneCompositor.swift AppleCam/Scenes/SceneOutput.swift AppleCam/Scenes/SceneMediaSource.swift \
  AppleCam/UI/PreviewDisplay.swift Tests/Integration/PreviewDisplayHarness.swift -o "$executable" 2>&1 | grep -E "error" || true
"$executable"
