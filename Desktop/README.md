# Clipboard Desktop

Windows/Linux desktop application built with SwiftCrossUI 0.10.0 and GTK 4.
The existing macOS SwiftUI/AppKit application remains independent. This package
uses the real Core store and native rich clipboard adapter; normal launches do
not insert sample history. Recording starts paused unless the user explicitly saves
record-on-start behavior. Runtime pause does not change that startup preference.

## Build

Swift 6.3.3 and SwiftSyntax 603.0.1 are pinned. Linux requires GTK 4 development
packages, pkg-config, libX11, libXfixes and libdbus-1 development headers. Run:

```sh
swift run --package-path Desktop ClipboardDesktop
```

On Windows, run `tools/desktop-ui/install-windows-gtk.ps1` in the Swift/Visual
Studio development environment, then build `Desktop`. It verifies fixed source
and runtime hashes and rebuilds GTK 4.22.4 with AccessKit C 0.18.0 enabled.
The upstream dependency archive is gvsbuild 2026.8.0. The fixed prefix is
`C:/gtk-build/gtk/x64/release`, matching its pkg-config files. Keep its `bin` on
PATH and `lib` in LIB. The script records exact versions in clipboard-runtime.json.

GTK is selected explicitly for Windows and Linux. The prior WinUI feasibility
build crashed when UI Automation traversed the view (SwiftCrossUI issue #787),
so production acceptance requires successful native accessibility controls on
the GTK/AccessKit backend. A different backend does not make failed tests pass:
the full window/search/copy/pin/settings/delete/persistence probe must succeed.

## Validation and scope

`.github/workflows/swiftcrossui-preview.yml` builds and operates the actual
Windows/Linux GUI. Windows uses native UI Automation with AccessKit, Linux uses
AT-SPI in isolated Xvfb/DBus. No keyboard events are synthesized. Reports and
screenshots are retained even when a probe fails. The `--smoke-root PATH` option
isolates synthetic fixtures; `--data-root PATH` selects an empty/real store
without seeding. Normal app data is stored under the OS Clipboard support root.

CP4 adds a native tray, configurable global shortcut, per-profile single-instance
activation, close-to-tray/reopen, explicit quit and atomic desktop settings. A
missing tray is reported, shortcut conflicts retain the previous binding, and
closing quits when neither tray nor shortcut can reopen the window. Windows uses
Shell_NotifyIcon/RegisterHotKey; Linux uses StatusNotifierItem/dbusmenu and XGrabKey.
Wayland global shortcuts are not advertised through XWayland. The IPC channel
exchanges activation only and never clipboard payloads. System services, Wayland and installer delivery remain subsequent layers
tracked in harness.json.cross_platform_delivery. Real keyboard/IME, focus
handoff and multi-monitor DPI acceptance remain separate interactive gates.
Windows GTK/AccessKit build and native control results are pending.

Local CP4 evidence: 166 macOS Core tests (one existing Keychain skip), Linux
6 native instance checks, 7 shortcut ownership checks, 10 private-session tray
checks and 18 GTK UI/lifecycle checks. Windows Core and native shell checks passed in Actions run 41016884988; Windows GUI results remain pending.

## Rich content and archives

CP5 captures/copies Unicode text, HTML, RTF, PNG/JPEG/TIFF/BMP and multiple file
references. Linux uses native MIME targets and bounded INCR transfers; Windows
uses registered formats, CF_DIB, CF_HDROP and CF_TIFF. Images are decoded off the
UI thread into bounded thumbnails; sensitive previews remain hidden. Source
filters use the actual clipboard owner's executable/WM_CLASS where available;
unknown source metadata is never replaced with the current foreground app.
Content settings configure type/source filters, capacity and maximum item size.

Export/import uses a self-contained `clipboard-history.clipboard.json` file,
with a 256 MiB maximum. Sensitive items are excluded; imports do not extract or
follow blob paths and recompute content identity. This format is separate from
the macOS application's ZIP archives. Original HTML/RTF formatting is preserved
on copy; plain previews do not execute HTML or load external resources. Complex
legacy RTF code pages may need the source application's plain-text sidecar.

Local CP5 evidence: 175 macOS Core tests (one existing Keychain skip), 156 Linux
Core tests and 24 GTK UI/rich-capture/lifecycle checks passed. Native format,
sensitivity, aggregate limits and large INCR transfers use independent peers.
Windows rich transport and UI results remain pending in CI.

## System services

CP6 adds Windows Credential Manager / Linux Secret Service credentials, per-user
startup integration and local OCR (WinRT on Windows, Tesseract on Linux). Linux
builds additionally need libsecret, Tesseract and leptonica development packages;
OCR needs installed language data (`eng`, plus `chi_sim` for Chinese). Credentials
have no plaintext fallback and remain separate from JSON settings. Private
profiles use distinct credential namespaces and cannot change the normal
profile's startup entry. The startup command uses `--background`; another launch
reopens the same process safely.

Remote OpenAI-compatible AI is disabled initially. Enable it explicitly and save
a model/endpoint; image uploads and automatic analysis have separate switches.
Requests use memory-only sessions, refuse redirects and bound responses while
receiving. Sensitive/concealed items never enter OCR or the network pipeline.
Remote file-content summaries and Apple-only models are not offered here. OCR
results can be copied separately without changing the original history item.

English/Simplified Chinese labels and native tray menus update live. System,
light and dark appearance synchronize GTK controls and SwiftCrossUI foregrounds
using notifications. Global-shortcut keyboard/IME/DPI still need interactive
acceptance. Local CP6: 181 macOS Core tests (one existing skip), full macOS app
build, 162 Linux Core tests, 12 native service checks, 12 tray checks and 32 GTK
UI checks passed. Native Windows service/UI results remain pending.
