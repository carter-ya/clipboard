default:
    @just --list

gen:
    xcodegen generate

build: gen
    xcodebuild -scheme ClipboardApp -destination 'platform=macOS' -derivedDataPath build build

run: build
    -pkill -x Clipboard
    sleep 0.3
    open build/Build/Products/Debug/Clipboard.app

build-release: gen
    xcodebuild -scheme ClipboardApp -destination 'platform=macOS' -configuration Release -derivedDataPath build build

run-release: build-release
    -pkill -x Clipboard
    sleep 0.3
    open build/Build/Products/Release/Clipboard.app

package: build-release
    #!/usr/bin/env bash
    set -euo pipefail
    APP=build/Build/Products/Release/Clipboard.app
    VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
    mkdir -p dist
    DMG="dist/Clipboard-${VERSION}.dmg"
    rm -f "$DMG"
    hdiutil create -volname Clipboard -srcfolder "$APP" -ov -format UDZO "$DMG" >/dev/null
    shasum -a 256 "$DMG" | tee "$DMG.sha256"
    echo "Packaged: $DMG"

test:
    swift test --package-path Core

lint:
    swift-format lint --strict --recursive Core/Sources Core/Tests App

fmt:
    swift-format format --in-place --recursive Core/Sources Core/Tests App

logs:
    log stream --level debug --predicate 'subsystem == "com.clipboard.app"'

reset:
    rm -rf "$HOME/Library/Application Support/Clipboard"

scenario:
    swift run --package-path Core scenario-runner

clean:
    rm -rf build .build *.xcodeproj DerivedData dist

icon:
    swift tools/resize-icon.swift tools/icon-source.png App/Assets.xcassets/AppIcon.appiconset

sparkle-keys *ARGS:
    #!/usr/bin/env bash
    set -euo pipefail
    TOOL=$(find build/SourcePackages -name generate_keys -type f -not -path "*old_dsa_scripts*" 2>/dev/null | head -1)
    if [[ -z "$TOOL" ]]; then
      echo "Sparkle CLI tools not found under build/SourcePackages."
      echo "Run 'just build' once to let SPM fetch Sparkle, then rerun this recipe."
      exit 1
    fi
    "$TOOL" {{ARGS}}

sparkle-sign DMG:
    #!/usr/bin/env bash
    set -euo pipefail
    TOOL=$(find build/SourcePackages -name sign_update -type f -not -path "*old_dsa_scripts*" 2>/dev/null | head -1)
    if [[ -z "$TOOL" ]]; then
      echo "Sparkle CLI tools not found under build/SourcePackages."
      echo "Run 'just build' once to let SPM fetch Sparkle, then rerun this recipe."
      exit 1
    fi
    "$TOOL" "{{DMG}}"
