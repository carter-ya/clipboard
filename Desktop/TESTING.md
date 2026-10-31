# Desktop preview acceptance

Automated evidence is retained per CI run. A successful compile or readable
accessibility tree does not establish that controls work. Platform releases
remain blocked by the open interactive gates below.

## Automated gates

| Gate | Environment and evidence |
| --- | --- |
| Shared logic and existing macOS app | `swift-portability.yml`: real Core tests on Windows/Ubuntu/macOS, existing macOS app build |
| Native clipboard and services | Independent synthetic peers, bounded rich formats, sensitivity, credentials/startup/OCR and opt-in HTTP failure cases |
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
| Remote-to-local fallback | Private loopback service fails both requests. Native controls first prove local analysis is refused without its opt-in, then explicitly enable local processing and Retry; verify the actual local result, original bytes, clean quit and exactly two credential/cookie-free requests. Core tests cover per-kind automatic consent, stale/private items, original retry identity and cancellation after local-permission revocation. Hosted Windows/installed confirmation remains required. |
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
