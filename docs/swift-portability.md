# Swift core portability experiment

Date: 2026-10-29 (Asia/Shanghai). Base: `b4ac516`. Branch: `codex/verify-swift-cross-platform`.

## Finding

The existing Swift business core compiles and runs on Linux and Windows after
isolating Apple-only implementations and supplying portable hashing and logging
backends. Rewriting business logic in Rust is not a prerequisite. This
experiment initially validated the core. The subsequent native text clipboard
slice below validates a bounded portion of desktop integration; it is not a
complete Windows/Linux desktop application.

## Evidence

| Check | Environment | Result |
| --- | --- | --- |
| Original source obstruction | Linux arm64, Swift 6.1.3 | Original WorkspaceProvider fails with `no such module 'AppKit'` |
| Original Core baseline | macOS arm64, Swift 6.4 | 150 tests, 1 existing Keychain skip, zero failures |
| Modified Core | macOS arm64, Swift 6.4 | 153 tests, 1 existing Keychain skip, zero failures |
| Modified Core | Ubuntu 22.04 arm64 container, Swift 6.1.3 | 133 tests, zero failures |
| Complete macOS application | Local Xcode, Debug | Build succeeded; application was not launched |
| Synthetic rich-types scenario | macOS and Linux arm64 | Five checks passed on each platform |
| Remote Linux core | Ubuntu 22.04 x86_64, Swift 6.1.3 | 133 tests, zero failures; five scenario checks passed |
| Remote Windows core | Windows Server 2022 x86_64, Swift 6.1.3 | 133 tests, zero failures; five scenario checks passed |

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
The original sensitive-item persistence tests accept an already marked
`RawClipItem`. The native text slice additionally tests the supported Windows
and KDE clipboard hints, but does not establish complete detection across apps.

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
docker run --rm --init \
  --mount "type=bind,source=$PWD,target=/workspace,readonly" \
  --workdir /workspace \
  swift@sha256:0a58f05d6c3d3ab48d3cc6f72202fce9bdda52f79f1f6e581c018fa70a590c67 \
  bash -lc '
    set -euo pipefail
    apt-get update
    apt-get install -y --no-install-recommends libx11-dev libxfixes-dev xvfb xauth
    mkdir -p /tmp/clipboard-core
    tar -C /workspace/Core --exclude=.build --exclude=.swiftpm -cf - . |
      tar -C /tmp/clipboard-core -xf -
    swift test --package-path /tmp/clipboard-core
    swift run --package-path /tmp/clipboard-core scenario-runner rich-types
    xvfb-run --auto-servernum swift run --package-path /tmp/clipboard-core scenario-runner platform-clipboard
  '
```

The tested image is `swift:6.1.3-jammy` on arm64. This is not a Linux x86_64
result. Host tests used Swift 6.4 on macOS 27.0.1. No oldest-macOS runtime test
was performed.

The GitHub Actions workflow, `.github/workflows/swift-portability.yml`,
runs only on pushes of `codex/verify-swift-cross-platform` (or manual dispatch
after GitHub registers the workflow on the default branch). It prepares Ubuntu
22.04 and Windows Server 2022 x64 with Swift 6.1.3, runs Core
unit tests and the synthetic scenario, and uploads toolchain, test and scenario
logs. Only Core and workflow changes trigger push runs; report-only updates do
not rerun tests.
Swift version selection is verified before compiling. The Ubuntu installation
explicitly selects the extracted toolchain rather than the runner's preinstalled
Swift. Logs are copied to artifacts even if a test fails. Sequential test output
is preserved directly; the initial run's `--xunit-output` option did not
produce a report.

Both jobs in the corrected workflow completed successfully on Swift 6.1.3.
Windows and Ubuntu each passed all 133 core tests and five scenario checks.
Both uploaded artifacts containing `toolchain.log`, `core-tests.log` and
`scenario.log`. These results validate native x86_64 compilation and execution
of the business core on both operating systems.

- Original core commit: `aebafe277066d93fcddf57d706dee81cf5578907`.
- Workflow correction commit: `ec9314dd4f8d08382df38aaf4ec8922e423fe648`.
- Passing workflow: https://github.com/carter-ya/clipboard/actions/runs/40858523441
- Windows job: https://github.com/carter-ya/clipboard/actions/runs/40858523441/job/123395520872
- Ubuntu job: https://github.com/carter-ya/clipboard/actions/runs/40858523441/job/123395521341
- Windows logs artifact: `core-tests-windows-2022` (ID `12890378115`).
- Ubuntu logs artifact: `core-tests-ubuntu-22.04` (ID `12890072956`).

The core-only tested commit is `ec9314dd4f8d08382df38aaf4ec8922e423fe648`;
`c80b736` recorded those results. Native adapter work below is a subsequent
slice and is validated separately. Report-only pushes do not trigger a run.

The container copies package sources into disposable storage before building.
This permits SwiftPM to maintain its lockfile without writing to the host. Xcode
can add its app-level Sparkle pin to `Core/Package.resolved`; the saved Core
lockfile contains only Core dependencies.

The lockfile resolves transitive `swift-asn1` 1.7.3 (tools version 6.1). The
experiment therefore uses Swift 6.1+; compatibility with the project's original
Swift 5.9 toolchain requires a separate dependency-resolution check before merge.
The pinned crypto version is an experiment dependency, not a final dependency
policy.

Full local command logs and `github-results.json` are retained under ignored
`build/portability/` in the worktree. GitHub also retains both job logs and the
workflow artifacts. They contain test fixtures rather than the user's clipboard
history.

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
| Windows Server 2022 x86_64, Swift 6.1.3 | 139 unit tests, five core checks and six native text checks passed |
| Ubuntu 22.04 x86_64, Swift 6.1.3 | 140 unit tests, five core checks and six native X11 checks passed |
| macOS application build | Passed after platform module split; application was not launched |

Native slice CI evidence:

- Tested commit: `79b22d540145df4c9deefa21b1c9bdbef10470fe`.
- Passing run: https://github.com/carter-ya/clipboard/actions/runs/40864222410
- Windows job: https://github.com/carter-ya/clipboard/actions/runs/40864222410/job/123414764819
- Ubuntu job: https://github.com/carter-ya/clipboard/actions/runs/40864222410/job/123414764276
- Both `core-tests-windows-2022` and `core-tests-ubuntu-22.04` artifacts include
  the toolchain, unit test, core scenario and native clipboard scenario logs.
- The Windows and Linux test totals differ by the Linux-only Wayland capability
  rejection test. No native text integration check is skipped on either runner.

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

## SwiftCrossUI UI slice

`UIPrototype/` is an independent Swift package using SwiftCrossUI 0.10.0 with
WinUI on Windows and GTK 4 on Linux. It consumes the real Core history store and
native text clipboard writer; Core and the existing macOS product do not import
the UI framework. See `UIPrototype/README.md` for build instructions and limits.

The first Linux build with Swift 6.1.3 compiled the application but failed at
link time in the toolchain's Observation runtime. The UI slice now tests Swift
6.3.3 with SwiftSyntax 603.0.1. The existing core/native workflow stays on 6.1.3.

The prototype provides search, a selectable list, preview, copy, pin/delete and
settings navigation. Data lives in its own directory; capture is off by default.
The workflow builds the native backends, starts real windows, operates native
accessibility controls without key injection, checks the real persisted data
and clipboard output, and uploads screenshots and logs.

Local Linux arm64 validation with Swift 6.3.3 / GTK 4.6 passed seven checks:
window/history, native clipboard copy, Unicode search, pin/filter, settings
round trip preserving the search value, delete and persisted store contents.
History, search and settings screenshots were visually inspected. AT-SPI
Component.GrabFocus is rejected by this GTK version; search focus is explicitly
unverified and appears in the report limitations. The composed button labels
require locating the native button ancestor rather than invoking a text child.
GitHub Ubuntu 22.04 x86_64 also passed all seven checks in run
[40989864289](https://github.com/carter-ya/clipboard/actions/runs/40989864289),
tested commit `00ad70545427c3209ddd1f71b60da4600054f797`.

Windows Server 2022 x86_64 compiled and linked the full WinUI preview, but the
accessibility probe crashed the application. Run
[40992560628](https://github.com/carter-ya/clipboard/actions/runs/40992560628)
retained a Windows Application Error event: `Microsoft.UI.Xaml.dll` 3.1.5.0,
exception `0xc0000005`, offset `0xf59da`. This exactly matches the fault signature
reported for the same SwiftCrossUI / swift-winui / Windows App Runtime versions in
[SwiftCrossUI issue #787](https://github.com/moreSwift/swift-cross-ui/issues/787).
The underlying WinUI accessibility problem is also tracked in
[Microsoft issue #11028](https://github.com/microsoft/microsoft-ui-xaml/issues/11028).
Run [40996448799](https://github.com/carter-ya/clipboard/actions/runs/40996448799),
commit `7cd2ad6854e787e19055287700a462d100940599`, additionally proved that the
ordinary Windows window survives before any UI Automation traversal. Its native
screenshot visibly contains the three rows, Chinese text and preview. Traversing
the full view then crashes with the same DLL/exception/offset. A minimal
text/counter/button scene survives, but its text is not discoverable by the UIA
probe, so button interaction cannot be verified there either. Both full and
baseline diagnostic reports remain failing. The final screenshot pass repositions
only the probe window inside the small hosted desktop to avoid off-screen crops;
this is not a product window-placement or DPI acceptance test.

CI caches compiled dependencies. Windows cache extraction can break tracked
relative directory symlinks, so the workflow recreates only Git-tracked links
before rebuilding. Dependencies' source contents and pinned versions are kept.
The full Windows UI check remains a failure rather than suppressing the crash or
skipping controls.

Final combined CI evidence:

- Tested commit: `0256b4027dd934485f2b94d55a461bdf094dd4dc`.
- Run: [40997209832](https://github.com/carter-ya/clipboard/actions/runs/40997209832).
- Ubuntu job `123872999798`: build and all seven GUI checks passed.
- Windows job `123872999448`: build and native window startup/rendering passed;
  UI Automation traversal failed with exit `-1073741819` (`0xc0000005`). The
  Application Error event again names `Microsoft.UI.Xaml.dll`, offset `0xf59da`.
- The full Windows startup screenshot was visually inspected after positioning
  the probe inside the desktop: header, search, three rows including Chinese,
  preview, copy/pin/delete controls, settings and Ready footer are all visible.
  This proves rendering, not successful Windows control interactions.
- Artifacts `swiftcrossui-ubuntu-22.04` and `swiftcrossui-windows-2022` contain
  screenshots, `results.json`, application/build logs and Windows crash events.
  The Windows artifact also retains the failing minimal-scene report.
- Overall CI failed because the Windows operation probe crashes.

These tests do not claim interactive keyboard/IME or global hotkey focus handoff
acceptance.

## Remaining work

1. Keep native Windows and Linux core tests running as platform adapters are
   added. A passing core suite does not validate desktop integration.
2. Split Apple adapters into a separate target if the experiment is adopted;
   make hotkey interfaces independent of KeyboardShortcuts types.
3. Extend the validated native text clipboard slice to rich formats and
   source-app metadata; preserve sensitive-memory-only handling and the existing
   no-automatic-paste rule.
4. Resolve the Windows WinUI accessibility crash before accepting the UI port.
   Extend the SwiftCrossUI preview with tray, focus/input-method behavior, hotkeys,
   credential storage, startup, OCR and distribution for each platform.
5. Test Linux X11 and specific Wayland desktop environments separately. A
   headless core container test makes no claim about desktop integration.
