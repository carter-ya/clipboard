# Clipboard Desktop

Windows/Linux desktop application built with SwiftCrossUI 0.10.0 and GTK 4.
The existing macOS SwiftUI/AppKit application remains independent. This package
uses the real Core store and native rich clipboard adapter; normal launches do
not insert sample history. Recording starts paused unless the user explicitly saves
record-on-start behavior. Runtime pause does not change that startup preference.

## Build

Swift 6.3.3 and SwiftSyntax 603.0.1 are pinned. Linux requires GTK 4 development
packages, pkg-config, libX11, libXfixes, libdbus-1, libwayland, libsecret,
Tesseract and leptonica development headers. Run:

```sh
python3 tools/desktop-ui/build-desktop.py
swift run --package-path Desktop --skip-build ClipboardDesktop
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
exchanges activation only and never clipboard payloads. System services, Wayland and installer delivery are implemented in subsequent stack
layers tracked in harness.json.cross_platform_delivery. Real keyboard/IME, focus
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
Windows rich transport passed native CI; the full UI gate remains open.

## System services

CP6 adds Windows Credential Manager / Linux Secret Service credentials, per-user
startup integration and local OCR (WinRT on Windows, Tesseract on Linux). Linux
builds additionally need libsecret, Tesseract and leptonica development packages;
OCR needs installed language data (`eng`, plus `chi_sim` for Chinese). Credentials
have no plaintext fallback and remain separate from JSON settings. Private
profiles use distinct credential namespaces and cannot change the normal
profile's startup entry. The startup command uses `--background`; another launch
reopens the same process safely.

Local text summaries are optional lead-sentence excerpts, generated entirely on this device. Enable them in settings for manual use; automatic processing has its own opt-in. The result is labeled Local excerpt and retains the original clipboard item. This baseline uses neither a model nor the network and supports text/RTF/mixed clips with at least 100 readable characters. Apple language/entity models remain unavailable on Windows/Linux.

Remote OpenAI-compatible AI is disabled initially. Enable it explicitly and save
a model/endpoint; text summaries, image uploads and automatic analysis have separate switches. Turning off text summaries also excludes RTF and mixed text clips from manual and queued remote analysis. Local OCR and the explicit fixed-message connection test remain separate.
Requests use memory-only sessions, refuse redirects and bound responses while
receiving. Sensitive/concealed items never enter OCR or the network pipeline.
Test connection uses the current fields and the saved key only when selected. It sends a fixed tiny test message, never clipboard history, and does not save the configuration. The request can be cancelled; editing connection fields or leaving settings clears its result. Authentication, endpoint/model, rate-limit and network failures have separate localized guidance.

Copied UTF-8 text/code/data files can produce local excerpts or remote summaries, with independent default-off permissions. Only the first copied file is read, up to 1 MiB; paths/names are not added to requests. Local and remote automatic file processing recheck current permissions. Nonregular files and final symbolic links are refused. Text PDFs are decoded by a separate bounded native process; encrypted and image-only PDFs are unavailable. File and extracted text are each capped at 1 MiB, with at most 256 PDF pages. Apple-only models remain unavailable. OCR
results can be copied separately without changing the original history item. Analysis progress and failures belong to each item; switching selection shows that item’s state. A failed attempt offers a retry using the same engine. Progress metadata stays in memory and is discarded when the item is removed or the app quits.

English/Simplified Chinese labels and native tray menus update live. System,
light and dark appearance synchronize GTK controls and SwiftCrossUI foregrounds
using notifications. Global-shortcut keyboard/IME/DPI still need interactive
acceptance. Local CP6: 181 macOS Core tests (one existing skip), full macOS app
build, 162 Linux Core tests, 12 native service checks, 12 tray checks and 32 GTK
UI checks passed. Native Windows services passed Actions run 41030210039; the native Windows UI gate remains open.

SwiftCrossUI 0.10.0 hard-codes Unix C integer widths in four GTK wrapper calls. Windows uses `gulong=UInt32` and `gsize=UInt64`, so the reviewed patch in `Desktop/Patches/` uses the actual C typedefs. The build helper verifies the pinned revision, applies this patch idempotently and then builds. Use this helper for native builds; the application does not change its dependency revision or bypass native UI checks.


## Native Wayland

CP7 uses wlr data control on supported compositors (native Sway rich capture and
GTK controls verified). It does not use XWayland for capture. Restricted Wayland
sessions offer GTK copy-only history and accurately report unavailable recording.
Wayland provides no source application identity here. Global shortcuts require
the desktop portal and explicit approval; activation tokens are one-shot.
Private compositor/protocol fixtures do not prove physical keyboard/IME focus.

## Installable previews

CP8 uses `Desktop/VERSION`, independently from the macOS release. CI builds
optimized executables and uploads preview archives, installers, checksums, native
UI reports and a separate verified GTK dependency source bundle. These are
unsigned preview artifacts; no public release or automatic update is performed.

Linux (Ubuntu 22.04 x64/arm64):

```sh
python3 tools/desktop-ui/build-desktop.py --configuration release
python3 tools/desktop-package/package-desktop.py --binary Desktop/.build/release/ClipboardDesktop --platform linux --output dist
```

Extract the archive and run `python3 install.py`; see its README for system
runtime packages and upgrade/uninstall instructions. Swift runtime libraries,
resource bundles and dependency notices travel with the app. The installer does
not require administrator privileges and preserves user history/credentials.

Windows x64: after configuring the verified GTK environment and building release,
run `tools/desktop-package/build-windows-installer.ps1 -Binary PATH -Output dist`.
It verifies the GUI subsystem and recursive DLL imports before invoking Inno
Setup 6. The resulting per-user installer includes GTK, Swift and MSVC runtime
libraries. Quit all profiles before upgrading/uninstalling. Startup removal is
limited to this installation's own command; history and credentials remain.

CI tests install/upgrade/uninstall in a Unicode/spaced private directory. Linux
checks run with no Swift SDK and no network. Native pointer tests verify Copy
in a 640×480 logical viewport at 100%/200%; bounded hide/reopen loops check query,
focus, memory and file descriptors. Physical multi-monitor scaling, real IME
composition and shortcut focus still require interactive acceptance before a
platform release.

The reviewed GTK main-loop patch also releases one-shot callback contexts and
prevents zero-delay timer starvation of AccessKit idle actions. Native Windows
focus/value/button behavior remains a hard CI gate.

The automated and interactive acceptance checklist is in [TESTING.md](TESTING.md).

Each history presentation starts at the first matching item and clears the transient type filter, retaining search, source and All/Pinned scope. Tab changes clear the type filter; type changes select the first visible item. Deleting a selected item keeps the next visible neighbor, or the previous item when deleting the last row.

The native build helper builds and verifies `clipboard-pdf-worker` plus a fixed non-V8/non-XFA PDFium runtime. It checks published archive hashes and packages all PDFium dependency notices and provenance. PDF input/output use private pipes without document paths or contents in command arguments. The decoder has memory/CPU limits, a parent deadline and explicit owned cancellation.
