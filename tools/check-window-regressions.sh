#!/bin/bash
# Native UI checks: opens only synthetic fixture windows, never reads the clipboard
# or synthesizes keyboard events. Requires a logged-in macOS desktop session.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"
just build
products="$repo/build/Build/Products/Debug"
output="$repo/build/window-regressions"
fixture="$output/ClipboardWindowRegressionProbe.app"
mkdir -p "$fixture/Contents/MacOS" "$fixture/Contents/Resources"
sources=()
for source in "$repo"/App/*.swift; do
  case "${source##*/}" in main.swift|AppDelegate.swift|SparkleUpdater.swift) continue ;; esac
  sources+=("$source")
done
xcrun swiftc -parse-as-library -module-name ClipboardWindowRegression \
  -target "$(uname -m)-apple-macos13.0" -I "$products" -F "$products" \
  "${sources[@]}" "$repo/tools/window-regression.swift" \
  "$products/ClipboardCore.o" "$products/KeyboardShortcuts.o" \
  -o "$fixture/Contents/MacOS/ClipboardWindowRegressionProbe"
cp -R "$repo"/App/*.lproj "$fixture/Contents/Resources/"
cat > "$fixture/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.clipboard.window-regression-probe</string>
<key>CFBundleName</key><string>ClipboardWindowRegressionProbe</string>
<key>CFBundleExecutable</key><string>ClipboardWindowRegressionProbe</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>CFBundleDevelopmentRegion</key><string>en</string>
</dict></plist>
PLIST
results="$output/results.json"
rm -f "$results"
open -W -n "$fixture" --args "$results"
failures=$(/usr/bin/plutil -extract failures raw -o - "$results")
echo "Native window regressions: $failures failures ($results)"
test "$failures" -eq 0
