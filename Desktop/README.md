# Clipboard Desktop

Windows/Linux desktop application built with SwiftCrossUI 0.10.0 and GTK 4.
The existing macOS SwiftUI/AppKit application remains independent. This package
uses the real Core store and native text clipboard adapter; normal launches do
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
exchanges activation only and never clipboard payloads. Rich content, system
services, Wayland and installer delivery remain subsequent layers
tracked in harness.json.cross_platform_delivery. Real keyboard/IME, focus
handoff and multi-monitor DPI acceptance remain separate interactive gates.
Windows GTK/AccessKit build and native control results are pending.

Local CP4 evidence: 166 macOS Core tests (one existing Keychain skip), Linux
6 native instance checks, 7 shortcut ownership checks, 10 private-session tray
checks and 18 GTK UI/lifecycle checks. Native Windows results remain pending.
