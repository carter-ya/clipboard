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
    # Icon coordinates (140,200) / (400,200) must match the slot centers
    # baked into tools/dmg-background.png (see tools/dmg-background.swift).
    create-dmg \
      --volname "Clipboard ${VERSION}" \
      --background tools/dmg-background.png \
      --window-pos 200 120 \
      --window-size 540 380 \
      --icon-size 128 \
      --icon "Clipboard.app" 140 200 \
      --hide-extension "Clipboard.app" \
      --app-drop-link 400 200 \
      --no-internet-enable \
      "$DMG" \
      "$APP"
    shasum -a 256 "$DMG" | tee "$DMG.sha256"
    echo "Packaged: $DMG"

dmg-background:
    swift tools/dmg-background.swift tools/dmg-background.png

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

release-notes-check VERSION:
    #!/usr/bin/env bash
    set -euo pipefail
    # Sparkle picks a <sparkle:releaseNotesLink xml:lang=...> URL by system
    # language, so every supported locale must ship an HTML before we tag.
    # Keep this list in sync with App/<locale>.lproj/ directories.
    LANGS=(en zh-Hans zh-Hant ja ko de es)
    MISSING=()
    for LANG in "${LANGS[@]}"; do
      F="docs/release-notes/{{VERSION}}/${LANG}.html"
      [[ -f "$F" ]] || MISSING+=("$F")
    done
    if (( ${#MISSING[@]} > 0 )); then
      echo "Missing release notes for v{{VERSION}}:"
      for F in "${MISSING[@]}"; do echo "  - $F"; done
      echo
      echo "Copy docs/release-notes/1.0.1/<lang>.html as a starting point,"
      echo "then translate per locale. Tagging is blocked until all 7 exist."
      exit 1
    fi
    echo "release notes for v{{VERSION}}: ${#LANGS[@]}/${#LANGS[@]} present"

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
