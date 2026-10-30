# Swift Core platform baseline

The production workstream starts from main `2fd2a97` in
`codex/cross-platform-foundation`. Its stacked delivery plan and acceptance gates
are tracked in `harness.json.cross_platform_delivery`. Windows/Linux/macOS Core
regression checks now run on PRs and main rather than an experiment-only branch.

The findings below retain the original 2026-10-29 experiment evidence (base
`b4ac516`, branch `codex/verify-swift-cross-platform`). They are not a claim of
completed desktop UI support. Initial local CP1 validation: local macOS Core 153 tests,
one existing Keychain skip, zero failures; strict Core/App lint, five synthetic scenario checks and the full macOS Debug
application build passed. Subsequent three-platform CP1 CI passed (run 40998982090).

## Finding

The existing Swift business core can run on Linux after isolating Apple-only
implementations and supplying portable hashing and logging backends. Rewriting
business logic in Rust is not a prerequisite. This experiment does not establish
Windows support or deliver a Windows/Linux desktop application.

## Evidence

| Check | Environment | Result |
| --- | --- | --- |
| Original source obstruction | Linux arm64, Swift 6.1.3 | Original WorkspaceProvider fails with `no such module 'AppKit'` |
| Original Core baseline | macOS arm64, Swift 6.4 | 150 tests, 1 existing Keychain skip, zero failures |
| Modified Core | macOS arm64, Swift 6.4 | 153 tests, 1 existing Keychain skip, zero failures |
| Modified Core | Ubuntu 22.04 arm64 container, Swift 6.1.3 | 133 tests, zero failures |
| Complete macOS application | Local Xcode, Debug | Build succeeded; application was not launched |
| Synthetic rich-types scenario | macOS and Linux arm64 | Five checks passed on each platform |
| Windows | No Windows runner available locally | Not executed; branch-scoped workflow prepared |

Linux's test total is intentionally smaller: seven test files containing 23
Apple-specific tests are compiled only on macOS. Linux runs 127 existing core
tests plus six portability tests; macOS runs the original 150 plus three shared
portability tests. The Linux run does not use replacement fake implementations
of the real store, blob storage, filtering, hashing, or search.

The suite covers JSON/blob round trips, deduplication, searching, capacity,
pinning, import, corruption recovery and sensitive-item exclusion from disk.
New checks cover standard SHA-256 vectors, Unicode/space-containing storage
paths and repeated flushes, the Foundation-only writer contract, rich-text
payload preservation without a decoder, and private-by-default log interpolation.

## Minimal changes

- Keep the existing `ClipboardCore` target and its actual sources; no rewritten
  copy of the business core or final module split is introduced.
- Guard the macOS clipboard, hotkey, credentials, image encoder implementations
  and their platform-specific tests with `#if os(macOS)`.
- Declare `PasteboardWriting` and its errors independently of AppKit. Keep the
  `WorkspaceProvider` protocol and stub available on all tested platforms.
- Link KeyboardShortcuts only for macOS. Use CryptoKit on macOS and the pinned
  official `swift-crypto` 3.12.3 package's `Crypto` product on Linux/Windows.
- Retain OSLog on macOS. Supply a validation-only stderr backend elsewhere;
  interpolated values are redacted unless explicitly public.
- Preserve RTF/HTML payload bytes on Linux. When no plain-text sidecar is present,
  the preview remains empty until a platform decoder is implemented. This is an
  explicit functionality gap, not equivalent rich-text preview support.

The model still uses Apple UTI strings and source bundle identifiers. A future
platform adapter must normalize native formats and supply platform source IDs.
Sensitive-item persistence tests accept an already marked `RawClipItem`; they
**do not prove native sensitive-content detection on Windows or Linux**.

## Reproduce

On macOS, Linux, or Windows with Swift installed, from the repository root:

```sh
swift --version
swift test --package-path Core
swift run --package-path Core scenario-runner rich-types
```

On macOS, also build the existing application:

```sh
just build
```

Linux container reproduction (POSIX shell, source mounted read-only):

```sh
docker run --rm \
  --mount "type=bind,source=$PWD,target=/workspace,readonly" \
  --workdir /workspace \
  swift@sha256:0a58f05d6c3d3ab48d3cc6f72202fce9bdda52f79f1f6e581c018fa70a590c67 \
  bash -lc '
    set -euo pipefail
    mkdir -p /tmp/clipboard-core
    tar -C /workspace/Core --exclude=.build --exclude=.swiftpm -cf - . |
      tar -C /tmp/clipboard-core -xf -
    swift test --package-path /tmp/clipboard-core
    swift run --package-path /tmp/clipboard-core scenario-runner rich-types
  '
```

The tested image is `swift:6.1.3-jammy` on arm64. This is not a Linux x86_64
result. Host tests used Swift 6.4 on macOS 27.0.1. No oldest-macOS runtime test
was performed.

The GitHub Actions workflow, `.github/workflows/swift-portability.yml`,
runs only on pushes of `codex/verify-swift-cross-platform` (or manual dispatch
after GitHub registers the workflow on the default branch). It prepares Ubuntu
22.04 and Windows Server 2022 x64 with Swift 6.1.3, runs Core
unit tests and the synthetic scenario, and uploads toolchain, test and scenario logs. Only Core and
workflow changes trigger push runs; report-only updates do not rerun tests.
The first remote run is in progress. Its Ubuntu job passed 133 tests and the
scenario, but selected preinstalled Swift 6.4.1 instead of the requested 6.1.3.
The workflow now verifies the compiler version, selects the extracted Ubuntu
toolchain explicitly, and saves logs regardless of test success. Windows
results and the corrected run are still pending. A native Windows
Swift installation can execute the same three commands directly. No Windows
build success is claimed before that run finishes.

The container copies package sources into disposable storage before building.
This permits SwiftPM to maintain its lockfile without writing to the host. Xcode
can add its app-level Sparkle pin to `Core/Package.resolved`; the saved Core
lockfile contains only Core dependencies.

The lockfile resolves transitive `swift-asn1` 1.7.3 (tools version 6.1). The
experiment therefore uses Swift 6.1+; compatibility with the project's original
Swift 5.9 toolchain requires a separate dependency-resolution check before merge.
The pinned crypto version is an experiment dependency, not a final dependency
policy.

Full local command logs are retained under ignored `build/portability/` in the
worktree. They contain test fixtures rather than the user's clipboard history.

## Remaining work

1. Run the prepared tests on native Windows and handle any compiler/Foundation
   differences. This is the next portability gate.
2. Split Apple adapters into a separate target if the experiment is adopted;
   make hotkey interfaces independent of KeyboardShortcuts types.
3. Implement native clipboard capture/writeback and validate native format,
   source-app and sensitivity metadata. Preserve the existing no-automatic-paste
   and sensitive-memory-only rules.
4. Select a UI and implement tray, focus/input-method behavior, hotkeys,
   credential storage, startup, OCR and distribution for each platform.
5. Test Linux X11 and specific Wayland desktop environments separately. A
   headless core container test makes no claim about desktop integration.

## Native text clipboard slice

This slice adds `DesktopClipboard`, separate from `ClipboardCore`, and a small
`CDesktopClipboard` system-API shim. The business target does not link X11 or
Win32. The new Foundation-only `TextClipboardAccess` protocol, fake,
`TextClipboardMonitor` and `TextPasteboardWriter` live in Core.

- Windows reads/writes CF_UNICODETEXT, normalizes native CRLF and Core LF, and
  checks the inexpensive clipboard sequence number before reading content.
  Native exclusion and history hints mark incoming text as sensitive.
- Linux X11 reads/writes the CLIPBOARD selection, serves UTF8_STRING/TARGETS,
  and uses XFixes notifications to detect changes even when the owner remains
  the same window. A Dispatch socket read source serves ownership requests;
  it does not spawn or poll external clipboard commands. The KDE secret hint
  is preserved for sensitive writes and recognized on reads.
- Reads are bounded to 16 MiB and failures do not reach the store. Oversized
  entries produce SkipEvents. The existing store remains responsible for
  keeping sensitive payloads out of JSON and blobs.
- The command-line scenario launches an independent native peer process,
  exchanges synthetic Unicode/multiline text over the OS clipboard, writes a
  stored blob back for that peer to read, verifies a native secret marker and
  memory-only persistence, and rejects oversized text. A 30-second watchdog
  bounds the scenario and only checkpoint names enter failure reports.

| Check | Current result |
| --- | --- |
| macOS regression suite | 159 tests, 1 existing Keychain skip, zero failures |
| Linux arm64 unit suite | 140 tests, zero failures |
| Linux arm64 native X11 scenario | All six checks passed in isolated Xvfb |
| Windows native text scenario | CI run pending |
| Linux x86_64 native X11 scenario | CI run pending |

The workflow installs X11 headers/libraries and Xvfb on Ubuntu, runs the native
scenario under a virtual display, runs the same scenario against the Windows
runner clipboard, and retains `platform-clipboard.log`. No local user clipboard
is accessed by these tests. Local Xvfb containers use `--init` so its ready
signal reaches the waiting launcher rather than PID 1.

Limitations: text only; no image/file/RTF/HTML payloads, source-app attribution,
global shortcut, UI/focus/input-method testing, startup or credential adapters.
Native secret detection depends on source applications setting recognized
hints. Wayland is explicitly rejected even when DISPLAY is also present; this
experiment does not treat XWayland as native Wayland support. X11 INCR transfers
are unsupported; writes are bounded by the server's ordinary request size.
Oversized X11 reads can report a conservative byte-count lower bound. Clipboard
contention and changed owners are retried by the monitor, not logged. This is a
prototype, not a production-hardened desktop adapter.


CP2 promotes these adapters onto the latest-main delivery stack. The native checks
are rerun on PRs; previous experiment results are historical rather than proof
for the new branch. Clipboard capture/readback and sensitive-memory-only behavior
remain required on both Windows and Linux.

CP2 local macOS regression: 159 Core tests, one existing Keychain skip, zero
failures; strict Core/App lint passed. Fresh native CI results are pending.

Windows CP6 service CI confirms credential and startup checks, but OCR fails. The fixture wrapper reports only fixed OCR stage codes to distinguish WinRT, language, decode and recognition failures without logging content. Linux CP6 services and 32 GTK UI checks pass.

Windows OCR failure was traced to case-sensitive lookup of `SystemRoot` in a copied environment whose key is `SYSTEMROOT`. The native adapter now resolves it case-insensitively; the Python fixture uses Windows' case-insensitive environment mapping. Runtime OCR is rechecked by CI rather than skipped.


## CP6 current result and CP7 Wayland implementation

CP6 Core/services CI [41030210039](https://github.com/carter-ya/clipboard/actions/runs/41030210039)
is green on Windows, Ubuntu and macOS, including real Windows OCR, secure
credential/startup fixtures, and the existing macOS application build. The
case-sensitive `SystemRoot` lookup was corrected. Windows GTK with AccessKit
now compiles; the UI application still awaits native UI Automation validation.
SwiftPM 6.3 misparses drive-letter `.pc` variable assignments because it treats
any colon-containing line as a field; CP3 normalizes these variables to
`${pcfiledir}` relative paths without changing their resolved locations.

CP7 adds native `wlr-data-control-unstable-v1` capture/copy with a bounded,
event-driven Wayland client. Each read/write is capped at 16 MiB and pipe I/O
has a two-second deadline. The adapter watches the display socket while idle,
serves owned bytes while recording is paused, preserves rich MIME formats and
sensitive hints, and stops capture on compositor/session loss. It selects the
first advertised seat and does not capture the primary selection. Protocol
source, revision, license and generation instructions are in `Core/Protocols/`.
Wayland exposes no source application ID here; the UI explicitly explains that
app exclusions cannot identify unknown sources. Sensitive hints still apply.

On restricted compositors the GTK adapter can copy history but cannot monitor
other applications. It never starts a polling capture loop or reports recording
active. Ordinary GTK Wayland copy requires a user-input serial: its private
Sway fixture creates a pointer-only device and clicks the accessible Copy
button, then checks bytes using an independent `wl-paste` process. No keyboard
device/event, automatic paste, XWayland, host clipboard or user data is used.
Only an explicit `--smoke-root` profile can force this fallback for testing.

The global-shortcut adapter uses the official
[GlobalShortcuts portal](https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.GlobalShortcuts.html)
and [host Registry](https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.host.portal.Registry.html).
New permissions require Apply shortcut; startup may restore a previously
approved binding. Pending, denied and unavailable states never advertise an
active shortcut. Closing a session or losing its portal owner removes the
capability. Activation tokens are consumed once and forwarded to GTK before
window presentation. The compositor controls the actual assigned keys.

Local evidence: Sway native rich transport passes 23 checks, and full native
Wayland UI plus the GTK copy-only UI fixture each pass 32 aggregate checks.
The private DBus fixture verifies portal request signatures and lifecycle,
including application identity, denial/retry and activation tokens. This is
protocol evidence, not a physical shortcut/keyboard/IME pass. Weston confirms
that absent data control is reported unsupported; its headless GTK AT-SPI tree
did not register, so Weston UI is not marked passed. GNOME/KDE physical focus,
IME, multi-seat and multi-monitor/DPI remain platform release gates. No broad
RemoteDesktop permission is requested to bypass clipboard restrictions.

CP7 final local regression: macOS 182 Core tests (one existing Keychain skip), Linux 163 Core tests, X11 rich transport 23 checks, X11 GTK UI 32 checks, Sway GTK UI 32 checks, GTK copy-only fallback 32 aggregate checks, private portal protocol 13 checks, and Weston restricted-capability check all pass. Strict Swift formatting is clean.
