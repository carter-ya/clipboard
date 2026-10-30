# SwiftCrossUI Clipboard Preview

This is a separate Windows/Linux UI feasibility package. The existing macOS
application and `ClipboardCore` do not depend on SwiftCrossUI.

Versions: SwiftCrossUI 0.10.0, SwiftSyntax 603.0.1, Swift 6.3.3. Default backends
are WinUI on Windows and GTK 4 on Linux. Swift 6.1.3 was tried first; its Linux
Observation runtime fails to link with an undefined `swift::threading::fatal`
symbol ([upstream issue](https://github.com/swiftlang/swift/issues/75670)).

The preview uses the actual `JSONSnapshotClipStore`, searches and mutates real
Core items, and copies through the native `TextPasteboardWriter`. It opens a
separate prototype history directory and starts with synthetic sample snippets.
Clipboard recording is off by default and requires an explicit UI action.
Sensitive previews are masked. No automatic paste or keyboard event synthesis
is implemented.

## Build and run

Use Swift 6.3.3. On Ubuntu install `libgtk-4-dev`, `pkg-config`, `libx11-dev` and
`libxfixes-dev`, then:

```sh
swift run --package-path UIPrototype ClipboardPreview
```

On Windows, install the [Windows App Runtime 1.5 x64 installer](https://aka.ms/windowsappsdk/1.5/1.5.250108004/windowsappruntimeinstall-x64.exe)
required by the pinned Swift WinUI bindings. Build and run from the executable's
directory so the upstream bootstrapper can resolve its resource DLL:

```powershell
swift build --package-path UIPrototype --jobs 2 --product ClipboardPreview
$PreviewBin = (swift build --package-path UIPrototype --show-bin-path).Trim()
Push-Location $PreviewBin
try { .\ClipboardPreview.exe } finally { Pop-Location }
```

## Validation

`.github/workflows/swiftcrossui-preview.yml` builds and launches the actual
application on Windows Server 2022 and Ubuntu 22.04. The test scripts create
unique synthetic history directories and use native accessibility interfaces:
AT-SPI on GTK; UI Automation on Windows. No key events are synthesized.

They check window/data appearance, programmatic search-control focus, native
clipboard output from Copy, Chinese-text search, pin/filter, settings round trip,
delete, and persisted state. Screenshots and application/build logs are uploaded
with `results.json`. Linux uses Xvfb, an isolated DBus session and Openbox.

These checks do not verify physical keyboard dispatch, real Chinese IME
composition, global hotkey activation/focus return, tray behavior, multi-monitor
DPI, installer packaging, or native Wayland clipboard capture. Those require
separate interactive desktop validation. Passing headless checks is not full UI
acceptance.

Status: implementation added; Windows/Linux GUI results pending.
