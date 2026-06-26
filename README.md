# Clipboard

**English** · [简体中文](README.zh-Hans.md) · [繁體中文](README.zh-Hant.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Deutsch](README.de.md) · [Español](README.es.md)

A macOS menu-bar clipboard history utility. All data stays on your machine — no network, no sync, no tracking. Sensitive items live in memory only and are never written to disk.

## Features

- Global hotkey summons the history panel (unbound by default; first launch prompts you to set one)
- Four item kinds — text / rich text / image / file — with thumbnail previews
- Filter by kind + full-text search (OCR results on images are searchable too)
- Sensitive-content detection (passwords, card numbers, etc.): cached only, never persisted or exported
- Per-source blocklist (bundle ID blacklist)
- AI summaries: Vision OCR + NaturalLanguage entities; macOS 26+ can opt into Apple Foundation Models
- Localized UI: English / 简体中文 / 繁體中文 / 日本語 / 한국어 / Deutsch / Español
- Sparkle auto-update (no Apple signing required; EdDSA-verified)

## System requirements

macOS 13 Ventura or later. Both Apple Silicon and Intel are supported; Foundation Models summaries require macOS 26+ with Apple Intelligence enabled on the device.

## Installation

### One-liner script (recommended)

```bash
curl -fsSL https://carter-ya.github.io/clipboard/install.sh | bash
```

The script fetches the latest DMG → verifies SHA-256 → quits a running Clipboard if any → copies to `/Applications/` → runs `xattr -cr` to strip the Gatekeeper quarantine attribute. Launch from Launchpad or Spotlight afterwards.

### Manual install from GitHub Release

1. Download the DMG matching your Mac's chip from the [Releases page](https://github.com/carter-ya/clipboard/releases/latest): `Clipboard-<version>-arm64.dmg` for Apple Silicon, `Clipboard-<version>-x86_64.dmg` for Intel (Apple menu → About This Mac shows your chip)
2. Double-click to mount, drag `Clipboard.app` into `Applications/`
3. **Strip the Gatekeeper quarantine attribute** (this project does not use Apple Developer ID signing / notarization):

    ```bash
    xattr -cr /Applications/Clipboard.app
    ```

4. Launch. The first-run wizard asks you to set a global hotkey (`⌃⌥⌘V` or `⌘⇧V` recommended).

> If you skip step 3, macOS will refuse to open the app with "developer cannot be verified". You can still allow it via **System Settings → Privacy & Security → Open Anyway**, but `xattr -cr` is faster.

### Verify the download

Every DMG ships with a matching `.sha256` file. Download both to the same directory and compare hashes:

```bash
# <arch> = arm64 (Apple Silicon) or x86_64 (Intel)
shasum -a 256 Clipboard-<version>-<arch>.dmg
cat Clipboard-<version>-<arch>.dmg.sha256
# The first field of each line should match
```

(The second column of the `.sha256` file is the packaging-time repo-relative path `dist/...`, so `shasum -c` won't work directly.)

## Usage

- **⌃⌥⌘V** (or your chosen shortcut): open / close the history panel
- **↑ / ↓**: move between items
- **⏎**: write the selected item back to the clipboard and close the panel; you then press `⌘V` yourself (Clipboard never synthesizes keystrokes)
- **⌘F**: jump to the search field
- **⌘,**: open Preferences
- **Right-click an item in the panel**: Pin / Delete
- **Pinned items** are never evicted by the capacity cap

## Privacy

- All history data is stored under `~/Library/Application Support/Clipboard/`
- **Sensitive items** (anything macOS marks as `NSPasteboardTypeConcealed`, such as passwords from a password manager) are only cached in memory and cleared on quit; they never appear in `history.json`, `blobs/`, export archives, or log bodies
- No network, telemetry, or analytics
- You can block items by source app bundle ID (e.g. never record anything copied from your password manager)

## Auto-update

Ships with Sparkle (independent of Apple's signing chain; update packages are EdDSA-verified). Preferences → General → Updates lets you check manually, or the Scheduled Check Interval (default 24 hours) runs automatically.

## Development

### Prerequisites

```bash
brew install just xcodegen swift-format
```

Xcode 15+ (16 recommended).

### Common commands

```bash
just gen       # Generate .xcodeproj from project.yml (not committed)
just build     # Cold Debug build
just run       # Launch (menu-bar shell; no Dock icon because LSUIElement=true)
just test      # Run Core's 85 unit tests
just lint      # swift-format lint
just fmt       # swift-format in place
just logs      # Stream os.Logger output (subsystem com.clipboard.app)
just reset     # Clear local history data
just package   # Build per-arch Release DMGs (arm64 + x86_64) + SHA256 into dist/
just clean     # Remove build artifacts and the generated project
```

### Packaging

```bash
just package
# → dist/Clipboard-<version>-arm64.dmg  (+ .sha256)
# → dist/Clipboard-<version>-x86_64.dmg (+ .sha256)
```

### Project layout

- `Core/` — `ClipboardCore` Swift Package: all business logic, independently testable
- `App/` — macOS App target: menu-bar shell and composition root, no business logic
- `project.yml` — XcodeGen source; `.xcodeproj` is regenerated by `just gen` and **not committed**
- `harness.json` — the project's single source of truth; any divergence must be synced in the same commit

### Release process (maintainers)

1. Prepend a `## [x.y.z] - YYYY-MM-DD` entry to `CHANGELOG.md`
2. Bump `MARKETING_VERSION` in `project.yml` to `x.y.z`; increment `CURRENT_PROJECT_VERSION`
3. `git commit -am "release: x.y.z"`
4. `git tag -a vx.y.z -m "x.y.z"`
5. `git push && git push --tags` — GitHub Actions runs `release.yml`: builds both per-arch DMGs (arm64 + x86_64), signs each with the Sparkle private key, creates a Release with both DMGs + `.sha256` + per-arch `appcast-item-<arch>.xml`, and prints both appcast snippets to the workflow Step Summary
6. `release.yml` then auto-commits the refreshed appcasts to `main` — the per-arch `appcast-arm64.xml` / `appcast-x86_64.xml` plus the merged `appcast.xml` for older (≤1.0.4) installs still polling it — so no manual paste is needed. (Sparkle won't see the new version until GitHub Pages republishes.)

**One-time setup before the first release**:

1. Run `just build` once (fetches Sparkle via SPM)
2. `just sparkle-keys` generates an EdDSA keypair — the private key goes to the local Keychain by default; the public key is printed to stdout
3. Paste the public key (a base64 string) into both `project.yml` and `App/Info.plist` under `SUPublicEDKey`, replacing the `REPLACE_WITH_BASE64_EDKEY` placeholder. XcodeGen overwrites `Info.plist` from `project.yml` on each `just gen`, so missing the `project.yml` side silently reverts to the placeholder
4. Export the private key for CI: `just sparkle-keys -x sparkle_ed_priv.key` (`-x` is forwarded to `generate_keys`); `cat sparkle_ed_priv.key` and copy into a password manager, then **immediately `rm sparkle_ed_priv.key`**
5. Add `SPARKLE_PRIVATE_KEY` under Settings → Secrets → Actions, pasting the exported base64 key
6. Current owner is `carter-ya`; forkers must replace it with their GitHub username / org in: `project.yml`'s `SU_FEED_URL` default, the per-arch feed URLs in the `Justfile` `package` recipe, `docs/appcast.xml` / `docs/appcast-arm64.xml` / `docs/appcast-x86_64.xml`, `docs/install.sh` (`REPO` constant and header-comment URL), `CHANGELOG.md` link definitions, every `README*.md` file's install section (the install.sh URL), and `harness.json`'s `project.distribution`
7. Enable GitHub Pages: Settings → Pages → Source `Deploy from a branch` → Branch `main` → `/docs` → Save; the appcast will live at `https://carter-ya.github.io/clipboard/appcast.xml`
8. `just clean && just package` to **rebuild** — any DMG already in `dist/` was built against placeholder values and must not be uploaded

### Hard constraints (for contributors)

- Business logic stays in `ClipboardCore`; the UI layer depends on Core through protocols
- All logging goes through `os.Logger` (subsystem `com.clipboard.app`); no `print()`
- Never synthesize keyboard events (no CGEvent / AppleScript / Accessibility) — selecting an item writes to the clipboard only; the user presses `⌘V` themselves
- App Sandbox is not enabled; Mac App Store is not a distribution target
- Sensitive items stay in memory only, never on disk
- Three-queue discipline: `monitor_queue` (polling and filtering) / `store_queue` (hashing and persistence) / `main_queue` (UI)

See `harness.json` for the full set of conventions.

## License

TBD (to be decided before the first public release).
