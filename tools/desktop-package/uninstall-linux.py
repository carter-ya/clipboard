#!/usr/bin/env python3
"""Remove only this installation's recorded files, keeping history and credentials."""
import json
from pathlib import Path
import sys
sys.dont_write_bytecode = True
from linux_installation import APP_ID, lock_installation, manifest, quoted_exec, remove_managed

root = Path(__file__).resolve().parent
installation_lock = lock_installation(root)
value = manifest(root)
metadata = json.loads((root / 'installation.json').read_text())
if metadata.get('applicationID') != APP_ID or metadata.get('prefix') != str(root):
    raise RuntimeError('Invalid installation metadata')
entry, shortcut, startup = map(Path, [metadata['desktopEntry'], metadata['shortcut'], metadata['autostart']])
if entry.is_file() and ('X-Clipboard-InstallRoot=' + str(root) + '\n') in entry.read_text():
    entry.unlink()
if shortcut.is_symlink() and shortcut.resolve() == (root / 'bin/ClipboardDesktop').resolve():
    shortcut.unlink()
if startup.is_file():
    commands = {quoted_exec(root / 'bin/ClipboardDesktop') + ' --background',
                quoted_exec(shortcut) + ' --background'}
    if any('Exec=' + command in startup.read_text().splitlines() for command in commands):
        startup.unlink()
remove_managed(root, value)
print('Uninstalled Clipboard Desktop. History and credentials are preserved.')
