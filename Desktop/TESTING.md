# Desktop preview acceptance

Automated evidence is retained per CI run. A successful compile or readable
accessibility tree does not establish that controls work. Platform releases
remain blocked by the open interactive gates below.

## Automated gates

CI has two scopes. Ordinary pull requests run the complete Core unit suite on
Linux/Windows/macOS, native clipboard/service checks and one Debug desktop build
on Linux/Windows. The focused native desktop smoke opens the real history and
model settings, checks consent, cancels the owned native chooser and quits cleanly
without downloading optional model weights. This green PR scope is not full UI,
real-model or installable-package acceptance.

Windows PRs also run `smoke-windows.ps1 -KeyboardOnly` using the same Debug
executable. At the user's request this mode sends actual OS keyboard input on
the isolated Actions desktop. A dedicated native WinForms editor supplies the
other foreground window and receives explicit Ctrl+V. Each submission verifies
the expected owned foreground HWND and rejects held modifiers; it never retries
an input mutation. The checks cover the registered Ctrl+Alt+V shortcut, search
focus and editing, Tab/Shift+Tab, Space-activated settings, Enter activation,
Alt+F4/reopen, full English/Chinese text paste and absence of automatic paste.
Full acceptance repeats this against the installed Release executable without
development runtime/resource fallbacks. Existing accessibility and clipboard
tests retain their complete assertions and run independently.

Final integrated run [41379565901](https://github.com/carter-ya/clipboard/actions/runs/41379565901)
passes all 18 keyboard checks in both Debug and the installed Windows Release.
The PR48 merge tree matched that tested head exactly. Later input-fixture and
acceptance-record layers retain separately scoped evidence in `harness.json`.

Unicode input packets are labelled as Unicode input, not an IME composition
pass. `keyboard-capabilities.json` records installed legacy Chinese IME count
and distinguishes the optional actual Pinyin checks from the Unicode packet
checks. Mixed-monitor DPI and real suspend/resume remain unverified.

Manual runs may select `windows_input_environment: inspect` for a content-free
OS/display/input inventory, or `prepare` to request the official Chinese basic
typing capability and user input profile on that disposable Windows VM.
Preparation also starts the available Windows text-input service and requests the
system CTF monitor in that VM; service states are recorded without process scans.
Both modes run only the eight-minute-bounded environment job, with no Swift build,
model transfer, clipboard access, sleep or restart. Preparation then exercises
the actual Windows input method in an owned native editor: Latin key events
must produce the complete native `nihao` preedit without committed text,
Escape must cancel without committing, Space must commit the fixed first
Chinese result and a number key must commit the fixed distinct second result.
These exact results use the fresh pinned Windows Server/Pinyin dictionary;
a changed dictionary fails the fixture rather than accepting arbitrary text. No Unicode input packets supply
these results. `ime-receipt.json` records only fixed stages/counts. A failed
native probe may capture only its owned foreground synthetic editor for visual
diagnosis before cleanup. The provider ends its TSF UI-element handles while
its candidate window remains visible, so assertions use actual preedit and
exact committed output from Space/2 instead of treating an empty candidate-list
query as failed input. GTK app composition integration remains a separate gate. The default
is `off`; PR/main acceptance keeps its normal platforms and scope. The retained
`input-environment.json` separates provisioned resources from actual IME
composition/candidate evidence in that separate native receipt.
Native Windows Actions [41399764373](https://github.com/carter-ya/clipboard/actions/runs/41399764373)
passes seven independent native IME checks, including selection/caret handoff
and OS input-language switching. This proves the provisioned native editor;
the GTK application is checked separately below and physical hardware remains open.

The follow-up `application` mode with `platform: windows` and
`full_validation: false` provisions/preflights Pinyin, reuses the Debug build
and adds actual Win+Space language selection, Escape/Space/number-key candidate
behavior in GTK, and continued Chinese input after settings and hotkey reopen.
After Debug passes, this manual mode builds Release from its dependency cache
and runs the installed keyboard scope while skipping the full GUI/model suites
and optional model downloads. Installation/runtime integrity and upgrade/
uninstall checks remain active and the report names `keyboard_package`.
Full integration retains all native GUI/model suites and installed checks.
Ordinary PRs retain the existing keyboard checks without provisioning language
resources. Run 41399764373 passes all 25 keyboard/IME checks in both Debug and
the freshly installed Release, plus twelve keyboard-package/runtime/upgrade/
uninstall checks. PR50's merge tree matches its tested head exactly.
IME mode queries are read-only and bounded;
only real language/mode shortcuts and Latin key events change input.
Post-focus append checks establish the insertion point with actual Ctrl+A/Right,
validated independently in the owned native Pinyin editor. Native candidate
buttons must contain the complete expected pair before selection keys.
The private Windows Actions profile also enables a read-only native GTK state
receipt. Ctrl+A must establish the actual full selection; Right must then
produce a fresh collapsed end position on that same mapped, focused editor
before the script begins another composition. The receipt contains only
lengths, numeric widget identities, selection/cursor offsets and booleans.
It never sets text, selection or focus, and normal profiles/platforms cannot
enable it. The authorization function is exercised in 96 compiled cases.

The keyboard profile also starts classic Notepad from the pinned Windows Server
runner for each English/Chinese original. From that foreground empty document
it invokes the actual app shortcut and copies with Enter, requires the document
to stay empty until explicit paste, sends real Ctrl+V and Ctrl+S, checks the complete text
both in the native editor and saved file, checks clipboard revision continuity,
then closes the saved document with Alt+F4. Observation is bounded and restricted
to that exact spawned system executable/PID and its classic editor HWND. Failure
cleanup stops only the owned process. This adds eight checks with no model
downloads or additional builds. Run
[41406435639](https://github.com/carter-ya/clipboard/actions/runs/41406435639)
passes all 33 keyboard checks in both Debug and the freshly installed Release,
including all eight Notepad checks per configuration, plus independent native
IME 7 and keyboard-package/runtime/upgrade/uninstall 12. Ordinary Windows/Linux
PR run 41406405362 also passes (Windows keyboard 26). PR52's merge tree matches
its reviewed/tested head. This Notepad plain-text acceptance does not establish
Windows client hardware, browser/Office, rich-format or file paste.

Manual `windows_input_environment: browser` runs only the eight-minute native
browser reference job. It uses stock Chrome with a fresh private profile and a
local synthetic page, without a toolchain, app build or model transfer. The
browser starts suspended and enters a non-breakaway kill-on-close job before
resuming. Its private debugging endpoint must report the exact spawned process
and private page; every actual Ctrl+V checks the owned foreground HWND. The page
observes trusted paste events while preserving normal browser paste. Assertions
require complete Unicode text/newlines, HTML bold rendering, exact PNG render
pixels, and both native dropped-file names and bytes. The probe checks unchanged
clipboard revisions and termination of every owned job process plus profile
removal. Scripts never inject paste events or use the browser clipboard API.
`browser-input.json` names this reference-only scope: product capture/copy
integration is a separate gate. Native Windows run
[41417401975](https://github.com/carter-ya/clipboard/actions/runs/41417401975)
passes all eleven checks, including an actual teardown-failure cleanup regression
and independent exact UTF-8 CF_HTML header/body readback before browser input.
The original complete HTML text/default-bold assertions pass unchanged after
the reference writer supplies explicit UTF-8 bytes instead of a managed string.
This reference pass does not establish product or installed-app format acceptance.

The optional private `-KeyboardOnly -BrowserPaste` mode connects that same owned
browser receiver to actual Clipboard capture and copy. An independent native
writer supplies text/HTML/PNG/two existing files while capture is explicitly on;
the persisted new record and unique query must appear before capture is paused.
The actual Hide control establishes the hidden-window precondition of the
Mac-equivalent toggle shortcut. From empty foreground Chrome it must focus the app's
retained query; Enter must write a fresh clipboard revision, promote that record
and hide. Chrome must remain empty until actual Ctrl+V, then satisfy the unchanged
native reference text, HTML bold, PNG pixels and file-name/byte assertions.
Original file hashes must remain unchanged. The owned browser job/profile must
be removed on success or failure, and content-free diagnostics remain bounded.
The first product run exposed a real image-format interoperability defect: the
PNG rendered correctly but Chrome exposed no image File to paste handlers. The
Windows adapter now retains the original PNG first and adds a separately bounded
64 MiB premultiplied-alpha CF_DIBV5 representation, from which Windows synthesizes
CF_DIB. Undecodable or larger images retain their original PNG. A cheap native C
regression checks exact original bytes, top-down pixels/transparency, COM apartment
balance, malformed/large image fallback and the maximum sensitive bundle. The
product/browser Debug flow passes all 52 keyboard checks at head 8105a30 in run
41429868239; the independent browser reference passes 11 checks and Core passes
all 17 native PNG regressions in run 41429427987. The branch Release phase was
intentionally cancelled after the identical merged main tree started full UI and
installation acceptance in run 41433432627. That main run now passes all
Windows native/installed UI (182/210), Debug/installed keyboard (52/52), actual
model suites and full installer/runtime/upgrade/uninstall (17) checks. Manual application input and full integration add it after the existing
keyboard/IME/Notepad checks in Debug and
the installed Release; ordinary PRs keep their one-Debug-build scope and do not
start Chrome. A cheap browser reference gate runs before those integration builds,
and keyboard-package mode still refuses optional model fixtures/downloads.

A subsequent browser-fixture follow-up adds fully transparent and half-transparent
pixels to the same 3×2 multicolor PNG. The real paste event must expose a complete PNG
File whose bytes exactly match the independent native writer's original encoded
image, in addition to exact default DOM dimensions and RGBA pixels. A PNG signature
alone cannot establish original-file preservation. Native reference run
41434916229 passes all 11 checks. The same fixture and assertions pass the actual
product capture/copy/paste path in Debug and installed Release at head 5b95142
in run 41440536848, with all 63 keyboard checks per configuration.

Manual windows_input_environment richtext mode runs only an eight-minute native
RTF reference, with no toolchain, browser, IME provisioning, application build or
model download. A separately owned native RichEdit receives actual scanned Ctrl+V
from an independent ASCII RTF writer with Unicode escapes. The initially empty
document must retain exact Chinese/emoji/newlines; actual navigation/selection
keys expose the bold colored 12-point run and a distinct italic run to read-only
native observations. Clipboard revision must remain unchanged, actual Alt+F4
must close the receiver and both owned UI threads must stop. This reference is
also required to survive an actual delayed UI callback after its dispatch wait
times out. The regression reproduces a late-completion exception before the
wait-handle lifetime fix; a timed-out queued invocation must retain its event
until completion. Run 41438011509 reproduces that defect; the identical real UI
regression and all ten reference checks pass in run 41438520654 after the fix.
This reference alone does not establish application RTF copy or Office
compatibility. Content-free receipts are saved as richtext-input.json.

The optional private -KeyboardOnly -RtfPaste mode connects that receiver to the
real application. Capture must persist a new RTF record with its complete native
Unicode preview and uniquely select it before recording stops. From the empty
foreground recipient, actual Ctrl+Alt+V must restore the retained query; Enter
must hide the app, promote the same record and publish exact original RTF bytes.
The recipient must remain empty until actual Ctrl+V. The shared native reference
assertions then require all text and formatting, unchanged clipboard revision,
actual Alt+F4, retained app selection and complete owned-thread cleanup. Native
reference and product paths use the same style checker. Run 41440536848 at head
5b95142 passes all 63 keyboard checks in Debug and installed Release, native
browser 11, shared native RTF 10 and narrowed installer/runtime/upgrade/uninstall
12. Its reports and four-format browser plus RTF receipts have been audited;
exact PNG bytes/transparency and native RTF formatting are required in both
configurations. Main full Core run 41433432465 passes all three platforms.
Main UI run 41433432627 passes complete Linux native/installed checks (181/211)
and its models/Wayland/scaling/language/install suites. The same run passes
Windows native/installed UI (182/210), full installation (17), and the native
and installed actual text (23 each), model-operation (16 each) and file/PDF
(21 each) suites. All named CP9/CP10 component assertions have been re-audited
against all four complete native/installed UI reports. These hosted gates do not close
physical client, Office/additional formats, mixed-monitor DPI or suspend gates.
Manual application/full integration runs enable this
alongside the browser checks after a cheap native RTF preflight; ordinary PRs
retain one Debug configuration and do not start these optional receivers.

Pushes to `main` and manual runs with `full_validation: true` retain the complete
acceptance below, including real CPU models, Wayland, Release UI controls and
installation. They first run the Debug checks and save their dependency cache,
then build Release once and reuse that executable for full UI and package checks.
Manual `full_validation: false` runs only the ordinary scope on the selected ref.
Manual Desktop UI runs may also select `platform: windows` or `platform: linux`
to validate a platform-specific repair without repeating the other platform.
The default is `all`; pull requests and main pushes always retain both platforms.
Verified dependency-source archives are collected on relevant `main` pushes or
manual source-workflow runs, rather than for every stacked PR.

New commits cancel older runs of the same workflow for that PR or branch;
different PRs/workflows remain independent. Dependency caches are separated by
OS, architecture, compiler (and the macOS SDK), package, configuration and committed dependency
recipes. Keys use Git objects, so checkout line endings and SwiftPM lockfile
rewrites cannot change a restore/save pair. Compiled caches are saved before UI
acceptance; optional model weights stay outside these caches and uploaded builds.
`main` builds seed Debug/Release caches that subsequent PRs may restore. A cache
created only on another PR's merge ref cannot be shared between stacked PRs, so
the first compatible `main` integration must finish its cache-save steps before
cross-PR reuse is available. Application source edits still rebuild through
SwiftPM; cached binaries never replace the current-source build or test steps.

| Gate | Environment and evidence |
| --- | --- |
| Shared logic and existing macOS app | `swift-portability.yml`: real Core tests on Windows/Ubuntu/macOS, existing macOS app build |
| Native clipboard and services | Independent synthetic peers, bounded rich formats, sensitivity, credentials/startup/OCR and opt-in HTTP failure cases |
| History metadata | Bounded display-only batches: image analysis row snippets, localized capture time/recorded bytes and readable source labels. Nonexistent synthetic file targets prove names/count come from references without target-file reads; complete native URI-list/CF_HDROP readback and unchanged original preview/source/payloads remain required. Core checks cover cancellation, invalid dates/URLs, Unicode and display budgets. Windows/Linux native and installed feature checks pass in run 41379565901; physical client acceptance remains open. |
| History activation | Private native selection first proves a different row is selected without copying; pointer clicks then require fresh clipboard revision/ownership, full original readback, immediate persisted promotion and hide without process exit on two presentations with reordered rows. An unsupported-payload fixture requires a real failed copy, visible error/window and unchanged timestamp. Core tests reject duplicate activations and stale dismissal after presentation change/stop. Physical keyboard/IME delivery remains separate. |
| History selection | Private fixtures choose a later row through real search controls, then independently read fresh Copy results after reopen, kind/tab changes and middle/last-row deletion. Query/tab/source are retained on reopen; the transient kind resets. Keyboard/IME and row activation remain separate gates. |
| Linux native UI | Private Xvfb/DBus, native AT-SPI controls, search/pin/delete/settings/copy and shell lifecycle |
| Native Wayland | Private Sway without XWayland, independent wl-clipboard peers, portal protocol fixture and pointer-only copy fallback |
| Restricted Wayland | Weston reports absent data control; its unregistered headless AT-SPI tree is not a UI pass |
| Windows stack reserve | The native chooser candidate reserves 8 MiB without increasing the initial commit. CI reads actual x64 PE headers for debug/optimized builds and retains numeric metadata. It is accepted only after real native chooser, complete UI and installation gates pass; a header check alone does not prove the crash fixed. |
| Windows native UI | Actual GTK HWND, UI Automation focus/value/invoke, fresh native copy readback, OCR/theme/language and shell lifecycle pass (41158347664); physical gates remain below |
| Linux installation | Optimized archive, no Swift SDK/network, Unicode/spaced prefix, complete runtime closure, guarded upgrade/uninstall, preserved history/startup and selective removal |
| Linux compact layout | Full wide-action bounds plus 640×480 logical viewport at virtual scale 1/2, editor/header-control continuity, readable history row, native pointer Copy and Unicode readback |
| History archive interoperability | Mac NSFileCoordinator fixture, root/wrapper ZIP layouts, original JSON dates, content/CRC validation, sensitive exclusion, missing/duplicate counts, unsafe paths/types and decoded-size limits; native Linux chooser export/clear/import/order/dedup checks pass with private pointer activation for unexposed GTK 4.6 file rows; Windows default-name acceptance leaves the filename untouched in a private initial directory and requires a real clipboard-history.zip file, since the shell may hide its known extension; native and installed confirmation passes on Windows/Linux in run 41379565901 |
| Startup entry ownership | Private native fixtures require conflicting commands to survive both replacement and removal; Linux also covers comments, Hidden/session restrictions, escaped TryExec, duplicate commands, oversized files and symlinks. UI retains drafts and shows localized conflict guidance. |
| Startup settings restoration | Private startup identity/nonexistent executable; external registration removal/restoration, native map/activation refresh, retained editor identity and unsaved draft; Windows/Linux native and installed checks pass in run 41379565901; real startup approval remains open |
| Fractional size policy | Core tests roundtrip exact byte thresholds, reject invalid/overflow/sub-byte inputs and admit a private 20 MiB file reference under a 32 MiB policy while still refusing a 16-MiB-plus-one transfer. Native settings save 0.5 and 32.5 MiB before restoring zero, preserving drafts and negative-value refusal. Windows/Linux native and installed checks pass in run 41379565901. |
| File text summaries | Private regular files exercise UTF-8/Unicode URLs, exact and excess byte budgets, invalid UTF-8/NUL, directories, final links and FIFO refusal. Nine native UI checks verify independent default-off permissions, fresh explicit body-only upload, cancellation of an active request on revocation and automatic local processing without more HTTP requests. PDF acceptance is covered separately; Windows/Linux native and installed checks pass in run 41379565901. |
| PDF text extraction | Six actual decoder checks cover text, Chinese/astral Unicode, malformed/empty PDFs, byte/page bounds. Native services exercise a Unicode copied PDF path and refusal cases. Four Linux real-pipe tests cover cancellation, deadline, output cap and failed-exit rejection; cancellation reproduces SIGPIPE before the thread-local fix. Native UI verifies automatic local PDF excerpts and explicitly allowed body-only uploads. Packages require the pinned worker/runtime and all notices. Windows/Linux native and installed checks pass in run 41379565901. |
| Local text excerpts | Four native checks use a private preseeded item and independent native writer to verify manual/automatic results, original-payload preservation, accurate local engine label, remote/image opt-outs and owned cleanup. Core tests cover Unicode/control/output budgets, rich text and sensitivity before resolution. Hosted Windows and installed checks pass in run 41379565901; archive interoperability has separate independent Mac-format fixtures. |
| Local generative backend | The optional CPU worker has separate real-model protocol checks and a Swift-adapter inference fixture. Committed synthetic cases cover seven response languages plus independent library/weather texts; review their saved sentences for facts as well as required concepts. Core guards sensitive content, copied-file bodies and truncation. Explicit license/installation controls and UI/scheduler/retry integration are implemented in the dependent layers below. Actual-model text/file modes exercise that integration; native Windows/Linux and installed model checks pass in run 41379565901. The separate excerpt action remains available. |
| Trained language/entity backend | Twenty-five independent tokenizer vectors cover original UTF-8 offsets, CJK/Korean, unassigned characters, controls, literal special tokens and truncation. Native checks identify seven language/writing forms, verify grounded BERT person/place/organization names and reject common nouns, dates, corrupted assets and alternate model files. A separately configured real Swift-adapter test exercises both language-only and entity modes. Entity installation uses the explicit license/acceptance flow. Model installation, removal and UI/scheduler/retry integration are implemented in the dependent layers below; native Windows/Linux and installed model checks pass in run 41379565901. |
| Remote-to-local fallback | Private loopback service fails both requests. Native controls first prove local analysis is refused without its opt-in, then explicitly enable local processing and Retry; verify the actual local result, original bytes, clean quit and exactly two credential/cookie-free requests. Core tests cover per-kind automatic consent, stale/private items, original retry identity and cancellation after local-permission revocation. Windows/Linux native and installed checks pass in run 41379565901. |
| Local image analysis | Native controls run OCR-first offline analysis, retain its progress/retry mode across selection, and independently read back the complete original PNG. Separate default-off automatic labels are saved without uploads; live revocation cancels the held classifier while keeping OCR enabled. Sensitive images remain ineligible after reveal. The private held-worker gate is available only in an isolated smoke profile; actual successful inference uses the bundled native helper. Windows/Linux native and installed checks pass in run 41379565901. |
| Per-item analysis progress | Private loopback fixture holds a request while selection changes, returns a failure and accepts retry. The selected result is persisted once; progress/failure never follow another item. Core tests cover duplicate starts, stale retry tickets, deletion/clear/stop and bounded metadata. Windows/Linux native and installed checks pass in run 41379565901. |
| Analysis type permissions | Old complete configurations retain text behavior; explicit false/null/type parsing, denied payload resolution, independent image/OCR permissions and queued/manual revocation are tested. Native settings must persist text opt-out without enabling remote AI or image uploads, then restore it. File/PDF text permission and extraction checks pass in the native and installed scopes of run 41379565901. |
| Explicit AI connection diagnostics | Five bounded Core tests cover fixed requests, credential opt-in, status classes and stale-result cancellation. Private native loopback fixture verifies success/401/retry/active cancellation, unchanged saved settings and no key/cookie/history transmission; 97 full Linux native checks pass. Windows/Linux native and installed checks pass in run 41379565901. |
| Desktop update discovery | Strict version/channel/platform/package/checksum selection and request privacy tests; private native loopback fixture covers 503/retry, installed version, compatible manual-release action and cancellation/settings handoff. Never open a real browser or installer during automation. Offline Linux arm64 runtime-only acceptance passes eight installation and 175 complete native UI/lifecycle checks, including the packaged version resource; hosted Windows and installed fixture checks pass in run 41379565901; real browser launch and manual update installation remain open. |
| Bounded lifecycle | Five warmup and twenty measured hide/reopen cycles; query/focus preserved and process RSS/FD growth bounded; not a multi-day soak |
| Windows installation | GUI subsystem, recursive DLL closure, per-user install/upgrade/uninstall, running-app guard and private history preservation; required native CI gate |
| Dependency sources | Verified GTK source/dependency archives, exact recipes, pinned revisions and checksums uploaded separately |

All tests use synthetic/private profiles. They never read a local user's desktop
clipboard or log content. A CI runner's isolated clipboard is used only for
synthetic fixtures. The explicitly authorized Windows KeyboardOnly mode sends
keys and pastes only between the owned app, native test recipient and explicitly
spawned Notepad documents; other
probes do not synthesize keyboard events or paste into another application.

## Current language and tokenizer checks

The shared Linux system-language resolver reads GNU message-language hints when
Foundation does not expose them. UI labels and default OCR use the same source;
macOS/Windows retain Foundation preferences. A child-process Linux regression
requires default-language OCR to recognize an unchanged public Chinese screenshot.
Remote text/image/file requests resolve the effective desktop language to the
prompt's human-readable response-language name while OCR retains language tags.

The text worker deliberately keeps the pinned Hugging Face 0.22.1 CJK isolation
ranges, including its U+2B820–U+2B91F gap. Independent adjacent-character cases
show that changing the lower bound alone breaks four reference cases. Those
checks exposed a separate cleaning defect: unassigned characters were removed.
The native cleaner now preserves them, matching all 25 independent token-ID and
original UTF-8 offset vectors. This is model compatibility, not complete Unicode
classification or identical Apple-model behavior.

The current Linux build passes 347 Core/platform tests (two existing optional
real-model fixture skips), six PDF decoder checks, eight image checks and 46
native text-worker checks. Twenty-three related macOS tests pass. An owned
child with English LANG/LC_ALL and Chinese LANGUAGE also verifies that local
model requests and rendered language names follow the UI's system preference.
A real pinned-model request with no explicit language produces a Chinese NASA/
Mars summary; its timing, repair purpose and other source facts were inspected.

The preceding product passes all 15 runtime-only installation/lifecycle gates,
211 complete native UI checks, eight model settings checks, nineteen text-model
checks, fourteen model-operation checks and nineteen file/PDF-model checks.
The latest language change was rebuilt and packaged separately. Ten additional
runtime-only installed checks use actual native Chinese controls with no
language override: bundled language identification renders an English-language
result name in Chinese, preserves the original record, keeps uploads disabled,
creates no optional-model root and quits cleanly. The checker is
`tools/desktop-ui/check-system-language-linux.py`; CI supplies the package and
string catalog explicitly. It requires a private DBus/Xvfb session and no Swift
SDK or networking. Complete Windows/Linux native and installed acceptance passes
in run 41379565901. These focused checks supplement that scope; the interactive
gates below remain open.

## Interactive release gates

Record the OS/build, desktop/compositor, monitor scales and observation for each
run. Keep these unchecked until a person verifies them with real input.

- [ ] Language rendering: verify readable glyphs and engine/result labels for all
      seven UI languages using the target desktop's fonts, including system
      language selection; native accessibility strings alone do not prove pixels.
- [ ] Windows client OS: install the unsigned preview on Windows 10/11 without a
      Swift SDK, launch from Start, confirm there is no extra console window.
- [ ] Real shortcut: grant/assign the Linux portal shortcut or choose the Windows
      shortcut, switch to another app, invoke it and verify search receives input.
      A denied/conflicting shortcut must retain an accurate capability state.
- [ ] Chinese IME: compose candidates, change selection, confirm/cancel composition,
      edit an existing query, and repeat after settings → history and hide → show.
- [ ] Multi-monitor DPI: move between differently scaled monitors; open, hide,
      restore and resize on each. Verify readable controls, visible actions,
      matching pointer hit targets and retained editor/composition state.
- [ ] Copy/paste by the user: copy text/image/files and manually paste into common
      target applications, checking native format fidelity and sensitive hints.
- [ ] Desktop sessions: test supported Sway portal integration and GNOME/KDE
      restricted capture explanations using their real permission UI. Do not
      describe XWayland capture as native Wayland support.
- [ ] Long session: run recording/pause, sleep/wake and compositor/session changes
      over an extended session; check memory, stale ownership and tray/shortcut
      recovery. A compositor disconnect must stop capture accurately.
- [ ] Upgrade/uninstall: quit every profile, upgrade, relaunch and verify history
      and preferences; uninstall and confirm unrelated files and credentials stay.

No main merge, public release, signing, or automatic update is part of these
preview acceptance scripts.

## Capability comparison with macOS

The Mac reference is `2fd2a97ff878ce37cb0f3beade23cb7ffcb9d2f2`.
A supported alternative does not establish identical model behavior.

| Capability | macOS reference | Windows/Linux desktop |
| --- | --- | --- |
| History filters | All/Pinned; Text/Image/File/Rtf/Mixed and All types; query-scoped counts | Same choices and count scopes through portable Core. The additional source-ID field is an explicit filter, not an installed-app picker. |
| Local image text | Vision OCR, with Chinese/English recognition | Native OCR uses available system/Tesseract language packs; missing languages or services remain capability failures. |
| Local image scene labels | Vision returns up to three classification labels when no text is recognized, then image dimensions as a last fallback | Analyze image locally runs OCR first, then the bundled offline SqueezeNet/ONNX Runtime CPU backend. Automatic labels require both automatic recognition and a separate default-off permission. Its ImageNet labels and accuracy differ from Vision. |
| Image descriptions through AI | Explicit image permission and configured endpoint | Supported only after the independent remote/image opt-ins, using a compatible image-capable endpoint. This does not supply offline classification. |
| Local text/file summaries | Mac NaturalLanguage/Foundation Models when supported | Independent default-off generated-summary and language/name permissions, with optional pinned CPU models and explicit license/import/download/verification/removal controls. Text and PDF bodies require separate local-file permission. Bounded excerpts remain a separately labelled action and authorized fallback. Model outputs differ from Apple models; Windows/Linux native and installed checks pass in run 41379565901. |
| Startup approval | OS login-item approval and user policy | Native registration/ownership and failure guidance are implemented; Windows Startup apps and Linux session policy can override registration. Real OS permission UI remains an interactive gate. |

The manual windows_input_environment images mode audits valid JPEG/TIFF through
the real C clipboard adapter without a Swift/application build or model transfer.
The owned runner generates synthetic 3×2 files and independently decodes them
with GDI+ to obtain reference BGRA pixels. Native checks require original format
bytes, standard bitmap availability/pixels, a single original history payload and
both ordinary/sensitive metadata, with private fixture cleanup. The older short
JPEG/TIFF scenario samples deliberately prove opaque-byte transport only and do
not establish image decoding or receiver interoperability. Run 41449124843 at
head 1dcc4b3 confirms a compatibility defect: both valid formats retain exact
original bytes and sensitivity but lack a standard bitmap for recipients, with
eight bitmap availability/pixel assertions failing. The Windows adapter now
extends its existing bounded WIC bitmap representation to valid JPEG/TIFF while
retaining originals and suppressing the derived duplicate on readback. The same
native regression passes all 27 checks in Core run 41451204402 at 1d2ac7b,
including independent pixels, original bytes, sensitivity and cleanup. That
head also passes three-platform Core and Windows/Linux UI, with 26 ordinary
Windows keyboard checks. PR59's main merge tree exactly matches the tested head;
full integration runs 41452804149/41452803944 are in progress.

The lightweight browser reference additionally generates valid opaque 3×2
JPEG/TIFF with independent GDI+ encoding/decoding. Each source must expose exact
native encoded bytes and a GDI+ bitmap, without a supplied PNG. Actual Ctrl+V
into owned Chrome must produce a trusted image/png paste and default DOM raster
with exact independently decoded RGBA pixels, unchanged clipboard revision and
the original native JPEG/TIFF bytes still present. The receipt distinguishes
retained native originals from Chrome's converted PNG; it does not claim that
Chrome exposes the original encoded file. Existing PNG checks still require
exact original encoded PNG bytes and transparency. This reference extension is
proven in native run 41453519072 at c13e5cd, with all 17 assertions passing.

The application browser mode also requires JPEG/TIFF through actual native
capture, a new persisted history ID, pause, hidden-window hotkey restoration,
Enter copy/promotion and explicit trusted Ctrl+V. Exact encoded source and copied
native bytes are checked separately from converted browser raster pixels. The
receiver must stay empty until explicit paste and its paste must not change the
clipboard revision. Every completed synthetic image record is removed through
the real Delete control, with exact ID removal and zero matching image rows,
so subsequent formats cannot pass by reusing a prior image. Existing PNG byte
and transparency requirements remain. This application extension is pending
Debug/installed execution; orientation and color-profile fidelity remain open.

The Mac reference preview explicitly applies ImageIO's embedded orientation.
The unchanged actual GTK decoder reproduced a parity defect with independently
generated orientation6 JPEG/TIFF: both decoded as 3×2 instead of Mac's 2×3.
The native decoder/hover regression covers absent and all eight EXIF orientations,
independent coordinate/color permutations, original in-memory bytes, empty and
truncated data and the existing 16 MiB encoded cap. Before the repair 38 of 113
assertions fail; after applying GDK Pixbuf's embedded transform before preview
and hover sizing, all 113 pass in an offline Linux arm64 container. Temporary
transform references are released on all exits, while the preview retains its
own reference. Existing decode/pixel/thumbnail bounds stay active. Normal
Windows/Linux UI CI now runs this actual-decoder check without a desktop or
clipboard. Hosted results and the changed preview's full UI are pending;
Windows clipboard-derived bitmap orientation and ICC/color fidelity are separate
unverified gates.

Recognizable credential text is classified by the shared Core sensitivity
filter, under the existing Mask sensitive items preference, enabled by default.
The capture policy recognizes sufficiently long sk-/project/Anthropic-style,
GitHub/GitLab, Stripe secret/restricted/webhook, Slack and npm token prefixes,
fixed AWS access-key identifiers and private-key headers. It checks token
boundaries/lengths and leaves ordinary words, short prefix placeholders and
Stripe publishable keys ordinary. No provider validation or network request is
performed. UTF-8 text is scanned in full instead of using the 256-character row
preview; UTF-16 and the bounded plain rendering of HTML/RTF are also checked.
Image bytes and copied file bodies are not scanned or opened by this policy.

Matches use the existing sensitive flag and constant credentialPattern reason,
so the normal password UI mask/reveal and AI/export exclusion apply. A recapture
of an already persisted ordinary duplicate must upgrade that exact record to
memory-only inline payloads, preserve ID/pinning/original Copy, remove obsolete
normal snapshot/blob references, clear summaries and reject late analysis
results. The UI receives the sensitive update before persistence suspension.
Synthetic unit tests exercise prefixes, negative cases, complete long text,
UTF-16, rich escaping, the capture/store/export path, no AI transport and the
old-duplicate/late-result regressions. The existing native Windows/Linux text
scenario additionally writes an unmarked synthetic key from its independent
process and requires inferred sensitivity, memory-only storage and exact
explicit Copy with a sensitive native hint. Hosted execution is pending.
Stored history/import reclassification and escaped rich-text tails beyond the
existing rendering budget remain follow-up gates; recognition of every possible
credential format is not claimed.

## Implementation history

The following notes retain the development sequence. Pending statements describe
those earlier stages. Current complete feature evidence is main run
[41433432627](https://github.com/carter-ya/clipboard/actions/runs/41433432627)
at 7885862, with 182/210 native/installed Windows UI checks and 181/211 Linux
checks, plus actual model and installer suites. Full Core/platform run
[41433432465](https://github.com/carter-ya/clipboard/actions/runs/41433432465)
passes all three platforms at that same main head. All named CP9/CP10 component
assertions are present and true in all four applicable retained UI reports;
harness.json records their exact scopes. The earlier feature run 41379565901
remains historical evidence. Later tests-only PNG/RTF acceptance at 5b95142 is
separately proven in run 41440536848 (63 Debug and 63 installed keyboard checks).
Physical/client gates remain open; these records do not claim identical entire
commit trees across the earlier and later evidence heads.

The offline backend now ships a hash-pinned SqueezeNet 1.1 model and ONNX
Runtime 1.31.1 CPU library with their licenses and dependency notices. Every
native build checks the official reference tensor and an independent RGB/crop/
normalization/postprocessing reference. The worker accepts only bounded bytes
through owned pipes, disables telemetry and applies process memory/CPU limits;
parent cancellation kills/reaps only that worker. Sensitive/concealed images are
refused before payload resolution. Installation checks execute the helper from
the real installed prefix without SDK paths and require its notices/provenance.
The bundled image classifier never downloads a model at runtime. Optional summary/entity models use the separate explicit, consented installation controls described below. Recognize text keeps its OCR-only behavior. Analyze image locally has its own
per-item progress, failure and retry mode; the original image remains separately
copyable. Automatic labels require both saved automatic-recognition and local-label
permissions; old settings keep OCR-only behavior. Saving revocation synchronously
cancels active automatic classification and rejects queued or late results, while
leaving OCR enabled. No remote or image-upload permission is enabled by this action.
Private native-control fixtures exercise failure/retry, selection changes, original
PNG readback, opt-ins and live revocation using synthetic images and the actual
classifier. Their held-worker fixture requires an isolated smoke profile and cannot
be enabled through normal settings. Hosted Windows and the
physical release gates remain required; backend tests do not establish identical
Vision labels or generative image descriptions.

The optional x64 generative worker requires AVX2/FMA/F16C plus OS XMM/YMM
support. It checks that capability before initializing the SDK and fails as
unavailable on unsupported CPUs. This is separate from the baseline desktop
application and trained language/entity worker. Native x64 inference timing and
quality remain required; the scalar build reached SIGXCPU in run 41258575790.

Model installation backend tests use tiny synthetic bytes and private temporary
roots, without real model transfers or desktop clipboard access. They cover
exact size/SHA, ownership, explicit consent, old-model preservation, import,
removal, symlinks and a cancellation-resistant fake transfer. Service tests use
an injected URLProtocol to exercise real ephemeral URLSession delivery, response
limits, anonymous requests and cancellation; redirect delegates verify allowed
hosts and stripped headers. Linux arm64 passes 311 total tests (two existing
real-model fixture skips); Mac passes all nineteen new tests and the application
build. The actual model controls, full notices/consent and installed Windows/Linux
UI acceptance remain separate gates. No startup download or end-user completion
is claimed by this backend layer.

PR39 review exposed a model-publication gap in the backup/move transaction.
An independent concurrent reader observes 484 missing-path samples before the
repair and zero afterward. Publication now uses one same-directory native rename
replacement, with no cross-volume copying; new ownership is recorded before
creating the target. The published name remains present through replacement and
a failed rename keeps the prior bytes. Linux arm64 passes all 314 Core/platform
tests (two existing real-model fixture skips); Mac passes all 21 model tests.
Windows filesystem confirmation remains required. Separately, native Ubuntu
run 41259526441 passes real generative inference (20.6 seconds), QEMU Nehalem
refusal and all nine multilingual quality cases; synthetic sentences were
inspected against their source facts. This does not close Windows or UI gates.

The model settings candidate has two content-free native capability queries and
31 new messages in all seven languages. Complete Apache-2.0/AFL-3.0 terms are
bundled as desktop resources, checked against fixed upstream notice sizes/SHA
before build and retained with complete worker attribution in installed packages.
Normal builds include native workers and small language/vocabulary resources;
they do not request optional summary/entity weights. Linux arm64 passes all 317
Core tests (two existing real-model fixture skips), all 181 complete native UI
regressions and all eight focused consent/import-cancel checks with networking
disabled. The actual model card renders are inspected. GTK 4.6 exposes the file
chooser as a filler, so its test checks a mapped owned X11 dialog rather than a
presumed AT-SPI role. Actual model installation/removal UI, native Windows,
installed/runtime and subsequent analysis integration remain required.

Model settings acceptance now passes all twelve offline runtime installation,
helper/notices, upgrade, uninstall and integrity gates, all 211 complete installed
native UI/lifecycle checks and all eight installed model controls. Both 100% and
200% layout suites pass eight checks each; the additional 200% model controls
pass all eight too. A first test invocation used a debug reference peer requiring
a debug-only Swift library; a current optimized peer fixes that harness setup.
Mac passes 24 related model/download/catalog tests and the existing app build.
The subsequent parent FIFO content-validation fix is incorporated; native
Windows UI and actual model-operation/analysis integration gates remain open.

The dependent local-text policy layer adds independent, default-off generative and
trained-language permissions. Its Core pipeline checks fresh eligibility before
model resolution, before payload processing and after inference; local fallback
order is generative → language/entities → excerpt, with separate authorization
for every phase and automatic/file gates. It owns no download or history write.
A scheduler pause lease cancels and drains owned work before model operations;
overlapping leases cannot resume one another. This layer is tested through
injected processors and held tasks. Normal UI/scheduler integration and actual
model removal/revocation acceptance remain pending in the next layer.

The desktop text UI now connects these policies to actual workers. Generated
summaries and language/name results show distinct sources. Model removal cancels
only analysis using that optional model and drains its owned native process before deleting files;
analysis permissions remain unchanged. Removing optional entity weights retains
bundled language identification. Saving revocation cancels the active engine,
including an automatic-only opt-out with manual use retained.

Private Linux actual-model acceptance uses `smoke-linux.py --local-text-only`
with explicitly supplied cached summary/entity model paths and the bundled model
JSON directory (`--model-definitions`). Its temporary profile and hard-linked
weights live beside the private cache, outside uploaded artifacts, and are
removed only after owned application cleanup. Startup verifies all model bytes.
The fixture can hold/fail an analysis to exercise retry and revocation; successful
requests always invoke real native inference. No model download or real desktop
clipboard access is needed. Windows actual-model UI and final installed-package
acceptance remain separate required gates.

Selective removal acceptance also removes an already absent entity model while
language-only work and unrelated generation are held. Both must keep running.
The completion receipt ensures the assertion observes the finished removal, not
a settings handoff race. Core regressions retain unrelated failure tickets and
pending IDs, and prove that the queue resumes only after the final pause lease.

The native Windows actual-model mode is `smoke-windows.ps1 -LocalTextOnly`
with explicit summary/entity file paths, the model JSON directory and a reference
peer. It requires the isolated GitHub Actions desktop. It covers actual inference,
progress/retry, original Copy, automatic/manual revocation, language-only retention
and unrelated/related model removal. A read-only sharing probe of the private
model observes an overlapping handle before removal; no process enumeration is
used. All normal 40-second control deadlines remain unchanged; new generation
result waits allow the native 90-second worker bound plus ten seconds to publish.

Both installed checkers can run the same actual-model controls with explicit
fixture paths. Optional weights and temporary profiles live outside the artifact
directory; installed Windows tests hide development resource bundles, and Linux
runtime tests mount only the reference executable and explicit test inputs.
The model builders' `--download-test-model-only` mode seeds that private cache
without rebuilding or changing application output. Four offline canary checks
verify cached-only behavior and corrupt-cache refusal. Normal application builds
and startup still never request optional weights.

Private model-operation acceptance uses `smoke-linux.py --model-operations-only`
or `smoke-windows.ps1 -ModelOperationsOnly`, with explicit summary/entity fixture
paths and the bundled model JSON directory. These modes own temporary profiles
beside the model cache. A nonproduction transfer fixture checks numeric progress,
failure/retry and cancellation without HTTP; successful import and repaired-model
inference use real fixed model bytes. Native choosers, local-copy cancellation,
license records, failed replacement retention, tamper rejection, exact repair and
relaunch without a passive transfer remain hard checks. Never damage a cache
hard link: only the imported copy may be corrupted. Both installed checkers run
the same controls while development bundles remain unavailable. Linux arm64
currently passes all fourteen native model-operation checks; native Windows and
final installed confirmation remain pending.

The first complete hermetic package now passes fourteen installation gates,
211 full UI/lifecycle checks, eight model settings, nineteen actual-model text
checks and fourteen model-operation checks. The repaired inference screenshot
waits for the real result, source label and idle control state. Both virtual
100% and 200% layout suites pass eight checks. Subsequent process-interruption
recovery adds persisted stage ownership and native noninheritable leases;
explicit retries/removal reclaim only abandoned recorded files. Stage cleanup
acceptance checks pending data, ownership records and leases together. The
rebuilt package containing this later recovery change and native Windows
execution still need final confirmation. Actual generated text/PDF file-body
inference remains separate from earlier local-excerpt and remote file checks.

The dependent real file-model mode is `smoke-linux.py --local-file-models-only`
or `smoke-windows.ps1 -LocalFileModelsOnly`, with explicit model paths, model
definitions and an independent clipboard peer. It creates three fixed private
text/PDF inputs, verifies separate file/automatic permissions, performs real
manual text-file and PDF-body generation plus automatic file generation, and
checks original native file Copy, immutable metadata and unchanged source bytes.
Successful inference uses the real worker without held/fake analysis fixtures.
Windows uses the selected fixture Python to create the same fixed PDF. Both
installed checkers include this mode. Final native and installed validation of
this dependent layer remains open.

Final new-label Linux arm64 file-model native acceptance passes nineteen checks:
manual text-file and PDF generation, automatic file generation, PDF language and
entity analysis, original file Copy, visible idle results, per-analysis metadata
and immutable file bytes. The three generated summaries are checked against
their fixed source facts. Reanalysis snapshots the current record after earlier
explicit Copy promotion; the timestamp change belongs to Copy, not analysis.
The preceding recovery package passes all fourteen installation, 211 full UI,
eight model settings, nineteen text-model and fourteen model-operation checks.
The final new-label file-model package now passes fifteen installation/upgrade/
uninstall/integrity gates, all 211 full UI/lifecycle checks, eight model settings,
nineteen text-model checks, fourteen model-operation checks and nineteen real
file-model checks in a runtime-only Linux image without networking or mounted
development resources. Native Windows exact-head validation remains open.

Sensitive recapture review regressions preserve all representations of the original
record even when a later capture shares its primary hash but carries fewer
formats. Snapshot removal must succeed before original blob references are
released; materialization, snapshot and physical-deletion failures retain an
explicit pending retry, and concurrent flushes cannot release another record's
shared reference. Six synthetic Core tests cover these cases and dispatch
revocation while credentials are held.

`test-sensitive-analysis-revocation.py` executes the actual Desktop store-event
switch with held tasks: sensitivity cancels the matching work while unrelated
work remains active. On macOS, `test-mac-sensitive-analysis.py` compiles the
actual application coordinator and remote summarizer against Core, using only
private temporary stores, volatile defaults, stub local engines and fake HTTP.
Automatic and manual held attempts must cancel without a local fallback, and
a held key-provider case must fail current-item authorization before dispatch
even without UI cancellation. These probes never start the application UI or
access the local desktop clipboard. Existing history/import reclassification
and escaped rich-text tails beyond parser budgets remain open.

The Notepad identity gate now waits up to ten seconds for the retained spawned
process's module metadata to become available. A different executable, exited
process or unreadable process is rejected before any keyboard submission.
It never adopts another PID/window or retries an input mutation. Eight
no-desktop regression cases run in both PowerShell runtimes before builds; a
Windows-native preflight then launches three owned empty Notepad documents,
checks the actual gate and cleans up only those processes. Its content-free
`input/notepad-process.json` records initial module availability; this preflight
has no keyboard or clipboard access and adds no application/model build.

This reproduces and repairs a startup-readiness defect. The earlier full main
integration failure reported only an identity mismatch, so its exact underlying
process state remains unknown until native evidence is collected. Full Debug/
installed keyboard, Pinyin and original-format paste checks remain required.

The actual Mac analysis probe supports both native SwiftPM `debug/Modules` and
Xcode `Products/Debug` module layouts. Its hosted module-lookup failure is
reproduced locally using real compiled artifacts in the native directory layout;
the corrected lookup passes the complete automatic/manual cancellation probes.

Hosted Windows run41470747030 passes all26 ordinary Debug keyboard checks
with full English/Chinese Notepad editor and saved-file readback, plus all3
native process-readiness checks. Both PowerShell gate suites and exact-head
review pass at a4e0861. All3 native launches had module metadata available
immediately; they do not reproduce the earlier main failure. Installed Release
and actual Pinyin/browser/RTF confirmation stay in final integration scope.

The secret-history policy follow-up applies the saved password preference
before initial history exposure on Mac and Desktop. Enabling it also reclassifies
current records; sensitive upgrades retain ID/pinning/all original formats, clear
old summaries and revoke owned analysis. Disabling does not downgrade sensitive
items. New inserts enforce the current policy even if a capture was queued
before the preference change. Imports validate complete payloads and owned
blob names/digests before target writes; detected credentials stay in memory
and the source archive remains unchanged. Unreadable current text stays masked
with an explicit pending cleanup that can retry after the original is restored.
Eight synthetic history-policy tests and the existing storage/import/analysis
suites cover these boundaries. Escaped rich-text tails beyond display parser
budgets remain tracked separately; no universal credential detector claim is made.

Credential privacy inspection now scans complete inert HTML/RTF text independently
of the64 KiB display and256 KiB display-source budgets. Escaped credentials beyond
both budgets are covered; ordinary long documents keep their existing display
truncation and remain ordinary. Valid long HTML attributes are scanned through
without forcing masking. Structural parser refusal (such as excessive RTF group
nesting or an unterminated tag) conservatively marks the whole record sensitive
with `uninspectableRichText`, rather than treating an unexamined suffix as safe.
No HTML engine, scripts, embedded objects, files or provider validation are used.
This recognizes defined patterns and supported text escaping; it does not claim
universal credential detection or full browser/Office rich-text semantics.
