# Clipboard Desktop preview for Linux

This package targets Ubuntu 22.04, x86_64 or arm64 as named in the archive. It
includes the Swift runtime. GTK, OCR and credential services use system packages:

```sh
sudo apt-get install libgtk-4-1 libcurl4 libxml2 libicu70 libssl3 libx11-6 libxfixes3 libwayland-client0 libdbus-1-3 libsecret-1-0 libtesseract4 liblept5 tesseract-ocr-eng tesseract-ocr-chi-sim gnome-keyring python3
```

Extract the archive, then run `python3 install.py`. Open Clipboard from the
application menu or run `~/.local/bin/clipboard-desktop`. Installation needs no
administrator privileges. Recording starts paused; enable it when ready.

Quit Clipboard and rerun the new package's `install.py` to upgrade. History,
settings and credentials are preserved. To uninstall, quit Clipboard and run
`python3 ~/.local/lib/clipboard-desktop/uninstall.py`. This removes the application's
own files, shortcut and startup entry while preserving history, credentials and
unrelated files. Delete an AI credential in Settings before uninstalling if you
want that credential removed.

X11 capture uses native selection notifications. Native Wayland capture requires
wlr data control (tested with Sway). Restricted Wayland sessions can copy history
but cannot record other applications. Source application identity is unavailable
on Wayland. Global shortcuts require a supported desktop portal and its approval.
The actual shortcut assignment is managed by the desktop.

This is a preview. Physical shortcut focus, Chinese IME and physical multi-monitor
DPI acceptance remain open. Automatic updates are not included. Third-party
notices and exact package/runtime hashes are included in `share/licenses` and
`package-manifest.json`.
