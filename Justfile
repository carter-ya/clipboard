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
    swift tools/resize-icon.swift tools/icon-source.png App/Assets.xcassets/AppIcon.appiconset
