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

## Remaining work

1. Keep native Windows and Linux core tests running as platform adapters are
   added. A passing core suite does not validate desktop integration.
2. Split Apple adapters into a separate target if the experiment is adopted;
   make hotkey interfaces independent of KeyboardShortcuts types.
3. Implement native clipboard capture/writeback and validate native format,
   source-app and sensitivity metadata. Preserve the existing no-automatic-paste
   and sensitive-memory-only rules.
4. Select a UI and implement tray, focus/input-method behavior, hotkeys,
   credential storage, startup, OCR and distribution for each platform.
5. Test Linux X11 and specific Wayland desktop environments separately. A
   headless core container test makes no claim about desktop integration.
