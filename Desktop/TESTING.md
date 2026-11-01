# Desktop preview acceptance

Automated evidence is retained per CI run. A successful compile or readable
accessibility tree does not establish that controls work. Platform releases
remain blocked by the open interactive gates below.

## Automated gates

| Gate | Environment and evidence |
| --- | --- |
| Shared logic and existing macOS app | `swift-portability.yml`: real Core tests on Windows/Ubuntu/macOS, existing macOS app build |
| Native clipboard and services | Independent synthetic peers, bounded rich formats, sensitivity, credentials/startup/OCR and opt-in HTTP failure cases |
| Linux native UI | Private Xvfb/DBus, native AT-SPI controls, search/pin/delete/settings/copy and shell lifecycle |
| Native Wayland | Private Sway without XWayland, independent wl-clipboard peers, portal protocol fixture and pointer-only copy fallback |
| Restricted Wayland | Weston reports absent data control; its unregistered headless AT-SPI tree is not a UI pass |
| Windows native UI | Actual GTK HWND, UI Automation focus/value/invoke, fresh native copy readback, OCR/theme/language and shell lifecycle pass (41158347664); physical gates remain below |
| Linux installation | Optimized archive, no Swift SDK/network, Unicode/spaced prefix, complete runtime closure, guarded upgrade/uninstall, preserved history/startup and selective removal |
| Linux compact layout | Full wide-action bounds plus 640×480 logical viewport at virtual scale 1/2, editor/header-control continuity, readable history row, native pointer Copy and Unicode readback |
| History archive interoperability | Mac NSFileCoordinator fixture, root/wrapper ZIP layouts, original JSON dates, content/CRC validation, sensitive exclusion, missing/duplicate counts, unsafe paths/types and decoded-size limits; native Linux chooser export/clear/import/order/dedup checks pass with private pointer activation for unexposed GTK 4.6 file rows; Windows default-name acceptance leaves the filename untouched in a private initial directory and requires a real clipboard-history.zip file, since the shell may hide its known extension; native/installed confirmation remains required |
| Startup entry ownership | Private native fixtures require conflicting commands to survive both replacement and removal; Linux also covers comments, Hidden/session restrictions, escaped TryExec, duplicate commands, oversized files and symlinks. UI retains drafts and shows localized conflict guidance. |
| Startup settings restoration | Private startup identity/nonexistent executable; external registration removal/restoration, native map/activation refresh, retained editor identity and unsaved draft; Windows execution required |
| Per-item analysis progress | Private loopback fixture holds a request while selection changes, returns a failure and accepts retry. The selected result is persisted once; progress/failure never follow another item. Core tests cover duplicate starts, stale retry tickets, deletion/clear/stop and bounded metadata. Windows/installed confirmation remains required. |
| Analysis type permissions | Old complete configurations retain text behavior; explicit false/null/type parsing, denied payload resolution, independent image/OCR permissions and queued/manual revocation are tested. Native settings must persist text opt-out without enabling remote AI or image uploads, then restore it. File summary capability remains open. |
| Explicit AI connection diagnostics | Five bounded Core tests cover fixed requests, credential opt-in, status classes and stale-result cancellation. Private native loopback fixture verifies success/401/retry/active cancellation, unchanged saved settings and no key/cookie/history transmission; 97 full Linux native checks pass. Exact-head Windows and installed execution remain required. |
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
