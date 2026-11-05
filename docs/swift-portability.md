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


## CP8 installation and runtime validation

The delivery stack now includes Windows per-user Inno Setup packaging and Linux
per-user archive installation, with explicit runtime/dependency manifests and
checksums. Linux bundles Swift libraries and declares Ubuntu 22.04 native GTK,
OCR and security dependencies. Windows packaging checks the GUI subsystem and
resolves recursive DLL imports from the verified GTK/selected Swift/MSVC inputs.
Installation lifetime locks prevent replacing a running application's bundle.
Upgrade/uninstall retain private history and credentials; uninstall removes only
owned application/startup/shortcut files. No main merge or release is implied.

The Linux arm64 debug package passed native UI controls in a container without a
Swift SDK, including installation guards, upgrade history preservation, selective
uninstall and rejection of a corrupted package. Optimized artifact validation,
100%/200% compact layouts and bounded repeated lifecycle checks are in progress.
GTK dependency source archives and exact build recipes were collected locally
with hashes; CI produces a separate source artifact alongside runtime previews.

Windows GTK now renders the real history window and exposes its accessibility
tree (run 41039328866), but native focus and minimal button action checks fail.
The pinned SwiftCrossUI backend has zero-delay Foundation run-loop timeouts that
can starve lower-priority GTK accessibility idle callbacks; the reviewed patch
adds a dispatch gap and releases callback contexts. The repair must pass native
controls in CI before Windows UI acceptance. Screenshot/tree evidence alone is
not a functional pass. Physical IME, shortcut focus and multi-monitor DPI gates
remain open even after virtual scaling tests succeed.


CP8 optimized Linux arm64 package acceptance passed in the runtime-only image
with networking disabled: installed GUI, application lifetime upgrade/uninstall
guards, eight install/upgrade/uninstall checks, and five layout checks at each
100%/200% scale. Twenty measured hide/reopen cycles after warmup preserve query
and focus: file descriptors remain 27; RSS changes 243576→245140 KiB. This bounded
regression is not a multi-day soak. The separate verified runtime source workflow
41042501729 is green. Windows GTK controls still fail after the scheduler patch;
the next native run includes content-free action diagnostics, an MTA UIA client,
default-priority AccessKit input dispatch and editable SetValue support.

The optimized installed Linux package also passes rich image/file capture and copy, real Tesseract OCR, and separate OCR-result copy with an independent native peer. The peer uses only the installed runtime libraries; the app loader path remains unmodified. See Desktop/TESTING.md for the remaining interactive release gates.

The final command-entry Linux package passes 63 installed GUI/lifecycle checks and eight installer checks; both scale suites pass six checks, including readable in-bounds history rows. Its latest measured lifecycle run keeps 27 descriptors and grows RSS by 1032 KiB. Bare PATH launch installation locks and localized service/privacy notes are covered.

Windows source privacy comparison now ignores executable filename case within
the `windows:` namespace, including user-configured rule spelling. The native
Swift adapter already lowercases observed Windows IDs, so the default lowercase
rules were unaffected; custom mixed-case rules could miss those observed IDs.
Public rule spelling and existing Mac/Linux comparisons are preserved. The
custom-rule capture/store regression fails before the fix and passes afterward;
all 205 Core tests pass in isolated Linux arm64. Windows Actions runs a synthetic
peer copied to a mixed-case executable name. Its message-only HWND owns the
clipboard and pumps native messages, allowing actual source identification; the
older generic peer uses a null owner and cannot provide that source fixture.
Checks cover both default and custom rules plus memory-only persistence. Native
Windows confirmation is pending; no real password manager is launched.

Desktop size preference `0` now disables user item-size filtering and survives
save/reload. Referenced file sizes are no longer mistaken for native transfer
buffer sizes in this mode; a 20 MiB synthetic file reference is accepted without
reading its body. Encoded clipboard transfers retain the 16 MiB native bound,
disclosed in all seven languages. Positive limits retain their previous behavior.
The regression fails before the fix; all 208 Core tests pass in isolated Linux
arm64. Native settings checks also cover saving zero and rejecting a negative
value without replacing it. Fractional preferences and captures exceeding the
platform transport bound remain parity work; this is not unlimited capture.

The optimized Linux arm64 build passes all 88 native UI checks, including both
size-setting cases. macOS passes 19 targeted settings/rich-clipboard/localization
tests. Windows probe syntax and native helper compilation pass; actual Windows
and installed-runtime confirmation remain pending.

Selected desktop images now provide a native hover preview. A second image is
prepared off the UI actor with a maximum 600-pixel edge, stays in memory, and
uses GTK's tooltip lifetime. The main picture scales within its layout proposal;
selection/unmap closes the anchor, and updates requery an open tooltip. Masked
sensitive images have no hover anchor, and original Copy bytes remain intact.
Linux GTK 4.6 exposes its custom tooltip as a panel containing a second image;
its AT-SPI window coordinates are translated through the private X11 window.
Focused native checks cover actual appearance, bounds, selection cleanup and
original PNG Copy. A synthetic 700x140 OCR image proves enlargement within the
600-pixel bound. All 208 Core tests and all eight layout checks at each scale
1/2 pass. All 91 full native Linux UI/privacy checks pass too, including sensitive
reveal revocation. Exact-head Windows and installed-runtime checks are pending.

The hover anchor uses a mapped native window-height budget (64–240 logical
pixels) instead of a 180-pixel minimum that could center a small image outside
the Windows viewport. The last mapped height survives hidden/internal size
proposals, matching the existing native-width policy. Source labels remain one
line with the full identity in native help. The candidate passes all 91 full
Linux native UI/privacy checks and all eight layout checks at each scale 1/2.
Windows probes now require the anchor to be onscreen before pointer movement;
exact-head Windows confirmation and low-height/physical display audit remain open.

Windows UI run 41255310855 confirms both real history activations and all manual
local-image progress, retry, native inference and original PNG Copy checks. The
automatic image fixture then races the asynchronous return from settings: a
generic Edit lookup can still target the outgoing settings tree. The fixture
now waits for the visible restored history query before clearing it, retaining
the exact two-item check and the existing action deadline. Native confirmation
of this candidate remains required.

Review of 4af85c9 finds the same outgoing-editor race at the second automatic
image settings handoff. Both returns now share a visible retained-query and
mapped-history-filter wait, preserving the exact two/three-item checks and
existing deadlines. Native Windows confirmation remains required.

Windows run 41261426989 confirms both restored-query handoffs and automatic
image acceptance, then reproduces a content-validation ordering problem. The
negative-size control is updated and the stored limit remains zero, but an
older successful save overwrites its error status. Invalid submissions now take
the same FIFO lease before parsing drafts or publishing errors. Keep the exact
negative-size rejection/persistence assertions; native confirmation is pending.


### Windows client capture crash: missing diagnostic output (2026-11-03)

The x64 preview was reported to exit on both text and image capture in Parallels Windows 11 ARM64. Six guest Application Error records identify `swiftCore.dll+0x168b6`, exception `0xc000001d`. Disassembling the packaged DLL maps that offset to the deliberate `ud2` at Swift assertion failure, rather than establishing an unsupported CPU instruction. A separately owned synthetic profile in the interactive guest session exits with the same code when launched without redirection; the identical executable with redirected stderr stays alive during the bounded observation. Recording is off and no user clipboard or history was read or changed. An initial Session 0 attempt instead failed GTK/DWM initialization and is not capture-crash evidence.

`JSONSnapshotClipStore.insert` logs every new item. The non-Apple logger used the legacy Foundation `FileHandle.write`, whose implementation force-tries the write. A normal GUI launch can have no writable stderr, whereas all prior UI probes redirected stderr. The logger now uses best-effort `write(contentsOf:)` so diagnostics cannot terminate capture. Interpolation remains private by default; macOS keeps OSLog.

`tools/ci/check-portable-logging.py` compiles the exact production logger into a GUI-subsystem Windows probe. Native checks require a completion receipt with absent/invalid/read-only stderr, then verify redacted output with a writable sink. Core and UI toolchains both run this regression. The Linux read-only sink reproduces the old implementation's crash, while the fix survives and retains redaction. Native Windows regression passes all four cases under both Core Swift 6.1.3 and UI Swift 6.3.3. PR #73 head `6241206` passes Core run 41574492674 on all three platforms (Windows: 354 executed, 2 platform-specific skips, zero failures) and Windows/Linux UI run 41574492695. Review receipt 6594988585 is clean; the initial negative-handle test-driver finding is fixed/resolved. The fix merged as `b6937a6`. Complete package run 41575886212 later fails its independent Windows model wait, while its Linux integration job succeeds. The scoped optimized candidate and ordinary Parallels client verification are recorded below. A debug-only standalone probe needs SwiftOnoneSupport, which the optimized package correctly omits; its loader failure is not a client acceptance result. This evidence does not close other client input/IME/DPI gates.


The complete main Windows attempt 41575886212 passes 182 native UI, 78 keyboard and four no-console logger checks, then fails `second_automatic_local_generation_started` while the application remains running. Its model-fixture cleanup removes the counters, so the exact wait failure is not established. A single fresh Windows-only run on the byte-identical reviewed tree (41579296477) fails browser preflight before application compilation. Neither failure is waived or reported as full acceptance.

An explicit manual `windows_capture_candidate=true` mode now requires `platform=windows`, `full_validation=false` and input environment `off`. It reuses the fixed compiler, verified GTK and frozen release dependency cache, builds only release, installs into an owned private location, launches the actual installed GUI with NULL standard handles and no inherited handles, and checks all five built-in synthetic text/PNG inserts finish. It requires three public persisted records, memory-only sensitive entries, continued process survival and owned uninstall. The fixture disables recording and shortcuts, sends no input and never touches a real clipboard/profile. Candidate metadata keeps `fullPlatformAcceptance=false`; existing full platform gates remain unchanged. This mode supplies a test candidate when a separate input/model reference gate blocks complete acceptance, without declaring a release ready. Native execution succeeds as recorded below.


Candidate run [41581073574](https://github.com/carter-ya/clipboard/actions/runs/41581073574), job 125735797129, passes all eight installed-regression checks and four logger checks. Artifact 13205399251 is explicitly `capture-fix-candidate`, with `fullPlatformAcceptance=false`. The workflow change passes Windows/Linux PR run 41581537027 and clean review receipt 6595922002 at `e6fbfa7`, then merges through PR #74 as `64bdd6d`. Candidate job/native-check definitions at its build head `c7bc0a7` are identical to that reviewed head; only concurrency isolation changes. Core/Desktop/App product trees match the already merged capture fix.

The optimized candidate executable also passes an ordinary GUI ShellExecute launch, without stderr redirection, on the user-provided Parallels Windows 11 ARM64 guest. It remains alive for the bounded 12-second observation and persists three synthetic public records with zero sensitive records. The same ordinary-launch path reproduced the old preview assertion failure. The profile is new, recording and shortcuts are explicitly off, and no real clipboard or normal history is accessed. The private fixture is cleaned. Clipboard sharing is disabled before temporary guest resume, then the initial paused state and sharing-on setting are restored. The installer is placed in the guest's already configured Downloads folder; no host-folder sharing is enabled. This does not verify real clipboard input, IME, model behavior or extended-session stability on that client.

Verified candidate hashes:

- Artifact ZIP: `55936326502c639996cc5915ef1c8b4d0cae310313688b6b1281f93a6663b3fa`
- Installer: `452d52a93d80f1e6bcbcee441225c5bf40d3c2bdfd0f788c88828448f889a5c8`
- Optimized executable: `86803ebfc4ac6f34f3237b29f885218450f2b31ccaf6dba40a28a01a54ddb9ae`

The local download name is `ClipboardDesktop-0.1.0-preview.1-windows-x64-capture-fix-c7bc0a7-setup.exe`, distinguishing it from the earlier same-version preview. Complete Windows platform acceptance remains open; the reported capture crash and this scoped candidate are verified.

### Windows tray activation follow-up (2026-11-03)

Direct single/double clicking the tray icon was reported to show history and immediately hide it. The old `c7bc0a7` executable reproduces this in an owned child on Parallels Windows 11 ARM64: after invoking the actual GTK Hide control once, `WM_LBUTTONUP` shows history and a subsequent `NIN_SELECT` hides it while the process remains alive. This is a toggle-policy defect, separate from the earlier logging crash. Tray activation now emits idempotent `showHistory`; the global shortcut retains `toggleHistory`. No delay, debounce, focus retry or production UI polling is added.

[PR #76](https://github.com/carter-ya/clipboard/pull/76) head `c401d7c3aa096c28206f178dcaca320c6393aff5` passes exact-head review (receipt 6597212270; no findings/threads), [Core Windows/Linux/macOS](https://github.com/carter-ya/clipboard/actions/runs/41591214380) and [PR Windows/Linux UI](https://github.com/carter-ya/clipboard/actions/runs/41591214351). It merges as `15c664f98da691c327a6d86730c4e8e2a137ed14`. The native fixture compiles the actual Win32 dispatcher, checks repeated release/selection/keyboard-activation callbacks, ignores hover and retains shortcut toggling. The initial standalone test compile failed on an existing MSVC CRT deprecation under `-Werror`; its compiler flags now acknowledge that CRT policy. This was a test-driver failure before execution, and superseded active CI was stopped.

[Candidate run 41591259622](https://github.com/carter-ya/clipboard/actions/runs/41591259622), job 125768289068, passes all 11 installed checks and four logger checks. Installed tray checks invoke Hide once through the owned native control, then deliver each activation callback once to a PID-validated shell HWND and observe visibility without mutation retries. The same verified optimized executable passes all three tray checks on the user's Parallels guest. Recording and shortcut registration are disabled in new private profiles; no real clipboard/history or keyboard input is accessed. Private profiles, unpacked package and generated shared helper files are removed. The guest stays running with clipboard sharing on, matching its initial state; its existing application installation is unchanged.

Verified artifact 13210099579 (`windows-capture-fix-candidate-x64`):

| File | SHA256 |
| --- | --- |
| Actions ZIP | `04df1196651d6dc509576164f41ea7d9280094e27d778affcc85d51b7dcd3bed` |
| Installer | `f72de8124e32a699f87f3435a5a80fd5d08e18fbcb406da3be1879e252f20a58` |
| Optimized executable | `8375820bb15802aab0c1440e6ce005513bc20c1aef595cb212db6f2051f249ca` |

The new Downloads filename is `ClipboardDesktop-0.1.0-preview.1-windows-x64-tray-fix-c401d7c-setup.exe`; the older candidate is preserved. This closes the reported tray hiding defect. Candidate metadata remains `fullPlatformAcceptance=false`: full model/browser/IME/upgrade and physical focus/DPI/suspend acceptance remain separate.

### Long RTF preview and localized menu regression

[Main desktop acceptance run 41970372206](https://github.com/carter-ya/clipboard/actions/runs/41970372206) timed out on two separate paths. In an isolated Linux arm64 desktop, displaying the first 65,536 characters of the 70,022-byte RTF fixture took 20.68 seconds with word-first wrapping and 1.60 seconds after switching long tokens to character wrapping for measurement and display. The original HTML and RTF bytes were read back through a separate X11 client. These are single local measurements of the native accessibility checkpoint.

On Windows the first Traditional Chinese selection raced with the transition from AI to General. The probe now waits for the localized menu to become available. The focused Windows 11 run exercised Traditional Chinese, Japanese, Korean, German and Spanish, checked the draft and editor identity in each language, then restored English.
