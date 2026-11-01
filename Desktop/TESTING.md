# Desktop preview acceptance

Automated evidence is retained per CI run. A successful compile or readable
accessibility tree does not establish that controls work. Platform releases
remain blocked by the open interactive gates below.

## Automated gates

| Gate | Environment and evidence |
| --- | --- |
| Shared logic and existing macOS app | `swift-portability.yml`: real Core tests on Windows/Ubuntu/macOS, existing macOS app build |
| Native clipboard and services | Independent synthetic peers, bounded rich formats, sensitivity, credentials/startup/OCR and opt-in HTTP failure cases |
| History metadata | Bounded display-only batches: image analysis row snippets, localized capture time/recorded bytes and readable source labels. Nonexistent synthetic file targets prove names/count come from references without target-file reads; complete native URI-list/CF_HDROP readback and unchanged original preview/source/payloads remain required. Core checks cover cancellation, invalid dates/URLs, Unicode and display budgets. Windows native/installed acceptance remains required. |
| History activation | Private native selection first proves a different row is selected without copying; pointer clicks then require fresh clipboard revision/ownership, full original readback, immediate persisted promotion and hide without process exit on two presentations with reordered rows. An unsupported-payload fixture requires a real failed copy, visible error/window and unchanged timestamp. Core tests reject duplicate activations and stale dismissal after presentation change/stop. Physical keyboard/IME delivery remains separate. |
| History selection | Private fixtures choose a later row through real search controls, then independently read fresh Copy results after reopen, kind/tab changes and middle/last-row deletion. Query/tab/source are retained on reopen; the transient kind resets. Keyboard/IME and row activation remain separate gates. |
| Linux native UI | Private Xvfb/DBus, native AT-SPI controls, search/pin/delete/settings/copy and shell lifecycle |
| Native Wayland | Private Sway without XWayland, independent wl-clipboard peers, portal protocol fixture and pointer-only copy fallback |
| Restricted Wayland | Weston reports absent data control; its unregistered headless AT-SPI tree is not a UI pass |
| Windows stack reserve | The native chooser candidate reserves 8 MiB without increasing the initial commit. CI reads actual x64 PE headers for debug/optimized builds and retains numeric metadata. It is accepted only after real native chooser, complete UI and installation gates pass; a header check alone does not prove the crash fixed. |
| Windows native UI | Actual GTK HWND, UI Automation focus/value/invoke, fresh native copy readback, OCR/theme/language and shell lifecycle pass (41158347664); physical gates remain below |
| Linux installation | Optimized archive, no Swift SDK/network, Unicode/spaced prefix, complete runtime closure, guarded upgrade/uninstall, preserved history/startup and selective removal |
| Linux compact layout | Full wide-action bounds plus 640×480 logical viewport at virtual scale 1/2, editor/header-control continuity, readable history row, native pointer Copy and Unicode readback |
| History archive interoperability | Mac NSFileCoordinator fixture, root/wrapper ZIP layouts, original JSON dates, content/CRC validation, sensitive exclusion, missing/duplicate counts, unsafe paths/types and decoded-size limits; native Linux chooser export/clear/import/order/dedup checks pass with private pointer activation for unexposed GTK 4.6 file rows; Windows default-name acceptance leaves the filename untouched in a private initial directory and requires a real clipboard-history.zip file, since the shell may hide its known extension; native/installed confirmation remains required |
| Startup entry ownership | Private native fixtures require conflicting commands to survive both replacement and removal; Linux also covers comments, Hidden/session restrictions, escaped TryExec, duplicate commands, oversized files and symlinks. UI retains drafts and shows localized conflict guidance. |
| Startup settings restoration | Private startup identity/nonexistent executable; external registration removal/restoration, native map/activation refresh, retained editor identity and unsaved draft; Windows execution required |
| Fractional size policy | Core tests roundtrip exact byte thresholds, reject invalid/overflow/sub-byte inputs and admit a private 20 MiB file reference under a 32 MiB policy while still refusing a 16-MiB-plus-one transfer. Native settings save 0.5 and 32.5 MiB before restoring zero, preserving drafts and negative-value refusal. Windows confirmation remains required. |
| File text summaries | Private regular files exercise UTF-8/Unicode URLs, exact and excess byte budgets, invalid UTF-8/NUL, directories, final links and FIFO refusal. Nine native UI checks verify independent default-off permissions, fresh explicit body-only upload, cancellation of an active request on revocation and automatic local processing without more HTTP requests. PDF acceptance is covered separately; hosted Windows/installed confirmation remains open. |
| PDF text extraction | Six actual decoder checks cover text, Chinese/astral Unicode, malformed/empty PDFs, byte/page bounds. Native services exercise a Unicode copied PDF path and refusal cases. Four Linux real-pipe tests cover cancellation, deadline, output cap and failed-exit rejection; cancellation reproduces SIGPIPE before the thread-local fix. Native UI verifies automatic local PDF excerpts and explicitly allowed body-only uploads. Packages require the pinned worker/runtime and all notices. Windows/installed confirmation remains required. |
| Local text excerpts | Four native checks use a private preseeded item and independent native writer to verify manual/automatic results, original-payload preservation, accurate local engine label, remote/image opt-outs and owned cleanup. Core tests cover Unicode/control/output budgets, rich text and sensitivity before resolution. Final hosted Windows and inherited Mac ZIP compatibility remain required. |
| Local generative backend | The optional CPU worker has separate real-model protocol checks and a Swift-adapter inference fixture. Committed synthetic cases cover seven response languages plus independent library/weather texts; review their saved sentences for facts as well as required concepts. Core guards sensitive content, copied-file bodies and truncation. Explicit user model installation and UI/scheduler/retry integration remain dependent work; the existing excerpt action is unchanged. |
| Trained language/entity backend | Fourteen independent tokenizer vectors cover original UTF-8 offsets, CJK/Korean, controls, literal special tokens and truncation. Native checks identify seven language/writing forms, verify grounded BERT person/place/organization names and reject common nouns, dates, corrupted assets and alternate model files. A separately configured real Swift-adapter test exercises both language-only and entity modes. Entity installation requires its license/acceptance flow; model installation and UI/scheduler/retry integration remain dependent work. |
| Remote-to-local fallback | Private loopback service fails both requests. Native controls first prove local analysis is refused without its opt-in, then explicitly enable local processing and Retry; verify the actual local result, original bytes, clean quit and exactly two credential/cookie-free requests. Core tests cover per-kind automatic consent, stale/private items, original retry identity and cancellation after local-permission revocation. Hosted Windows/installed confirmation remains required. |
| Local image analysis | Native controls run OCR-first offline analysis, retain its progress/retry mode across selection, and independently read back the complete original PNG. Separate default-off automatic labels are saved without uploads; live revocation cancels the held classifier while keeping OCR enabled. Sensitive images remain ineligible after reveal. The private held-worker gate is available only in an isolated smoke profile; actual successful inference uses the bundled native helper. Hosted Windows/installed confirmation remains required. |
| Per-item analysis progress | Private loopback fixture holds a request while selection changes, returns a failure and accepts retry. The selected result is persisted once; progress/failure never follow another item. Core tests cover duplicate starts, stale retry tickets, deletion/clear/stop and bounded metadata. Windows/installed confirmation remains required. |
| Analysis type permissions | Old complete configurations retain text behavior; explicit false/null/type parsing, denied payload resolution, independent image/OCR permissions and queued/manual revocation are tested. Native settings must persist text opt-out without enabling remote AI or image uploads, then restore it. File text permissions are covered separately below; PDF extraction remains open. |
| Explicit AI connection diagnostics | Five bounded Core tests cover fixed requests, credential opt-in, status classes and stale-result cancellation. Private native loopback fixture verifies success/401/retry/active cancellation, unchanged saved settings and no key/cookie/history transmission; 97 full Linux native checks pass. Exact-head Windows and installed execution remain required. |
| Desktop update discovery | Strict version/channel/platform/package/checksum selection and request privacy tests; private native loopback fixture covers 503/retry, installed version, compatible manual-release action and cancellation/settings handoff. Never open a real browser or installer during automation. Offline Linux arm64 runtime-only acceptance passes eight installation and 175 complete native UI/lifecycle checks, including the packaged version resource; real Windows confirmation remains required. |
| Bounded lifecycle | Five warmup and twenty measured hide/reopen cycles; query/focus preserved and process RSS/FD growth bounded; not a multi-day soak |
| Windows installation | GUI subsystem, recursive DLL closure, per-user install/upgrade/uninstall, running-app guard and private history preservation; required native CI gate |
| Dependency sources | Verified GTK source/dependency archives, exact recipes, pinned revisions and checksums uploaded separately |

All tests use synthetic/private profiles. They never read a local user's desktop
clipboard, synthesize keyboard events, paste into another application or log
content. A CI runner's isolated clipboard is used only for synthetic fixtures.

## Interactive release gates

Record the OS/build, desktop/compositor, monitor scales and observation for each
run. Keep these unchecked until a person verifies them with real input.

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
| Local text/file summaries | Mac NaturalLanguage/Foundation Models when supported | Bounded local excerpts, including text-file/PDF extraction. These are labelled excerpts, not generative summaries or identical Apple-model output. |
| Startup approval | OS login-item approval and user policy | Native registration/ownership and failure guidance are implemented; Windows Startup apps and Linux session policy can override registration. Real OS permission UI remains an interactive gate. |

The offline backend now ships a hash-pinned SqueezeNet 1.1 model and ONNX
Runtime 1.31.1 CPU library with their licenses and dependency notices. Every
native build checks the official reference tensor and an independent RGB/crop/
normalization/postprocessing reference. The worker accepts only bounded bytes
through owned pipes, disables telemetry and applies process memory/CPU limits;
parent cancellation kills/reaps only that worker. Sensitive/concealed images are
refused before payload resolution. Installation checks execute the helper from
the real installed prefix without SDK paths and require its notices/provenance.
The application never downloads a model at runtime. Recognize text keeps its OCR-only behavior. Analyze image locally has its own
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
