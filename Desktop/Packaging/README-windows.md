# Clipboard Desktop preview for Windows

Use the x64 installer on Windows 10 (build 19041+) or Windows 11. It installs for
the current user without administrator privileges. Swift, GTK/AccessKit and MSVC
runtime DLLs are included; a Swift development environment is not required.

Open Clipboard from the Start menu. Recording starts paused. Text recognition
uses Windows OCR and requires an installed OCR language. Remote AI is disabled
initially and has separate image-upload and automatic-analysis switches.

Local file excerpts and remote file text uploads have independent default-off
controls. The included native PDF decoder accepts text PDFs, with 1 MiB limits
for files and extracted text and at most 256 pages. Encrypted and image-only PDFs
are unavailable. Decoder dependency notices and pinned build provenance are in
`share/licenses/pdfium`.

Quit all Clipboard windows before upgrading or uninstalling. Run a newer installer
to upgrade in place. Use Windows Apps settings or the Start menu uninstaller to
remove the application. History, preferences and OS-stored AI credentials are
preserved. The app's own matching startup registration is removed. To remove an
AI credential too, delete it in Clipboard Settings before uninstalling.

The ZIP is a portable alternative: retain its bin/lib/share layout and run
`bin/ClipboardDesktop.exe`. Its history still uses your normal Clipboard support
directory, and opening an existing profile reactivates its current process.

Preview installers are unsigned and automatic updates are not included. Physical
shortcut focus, Chinese IME and physical multi-monitor DPI acceptance remain open.
Third-party notices and package hashes are in `share/licenses` and
`package-manifest.json`.

The matching GTK library sources and build recipes are provided alongside the
installers as `ClipboardDesktop-third-party-sources-gtk4.22.4.tar.gz`, with a
source manifest and checksums. GTK remains dynamically linked.
