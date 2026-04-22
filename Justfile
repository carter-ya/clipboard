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
    rm -rf build .build *.xcodeproj DerivedData

icon:
    #!/usr/bin/env bash
    set -euo pipefail
    src=tools/icon-source.png
    dst=App/Assets.xcassets/AppIcon.appiconset
    for pair in \
      "icon_16x16.png:16" "icon_16x16@2x.png:32" \
      "icon_32x32.png:32" "icon_32x32@2x.png:64" \
      "icon_128x128.png:128" "icon_128x128@2x.png:256" \
      "icon_256x256.png:256" "icon_256x256@2x.png:512" \
      "icon_512x512.png:512" "icon_512x512@2x.png:1024"; do
      name="${pair%:*}"; size="${pair##*:}"
      cp "$src" "$dst/$name"
      sips -s format png -Z "$size" "$dst/$name" > /dev/null
    done
