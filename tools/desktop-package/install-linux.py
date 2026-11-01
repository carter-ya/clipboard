#!/usr/bin/env python3
"""Install or upgrade a private-user Clipboard package without changing history."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import uuid
import sys
sys.dont_write_bytecode = True
from linux_installation import APP_ID, absolute, lock_installation, manifest, owned_files, quoted_exec, remove_managed, xdg

parser = argparse.ArgumentParser()
parser.add_argument('--prefix', default=str(Path.home() / '.local/lib/clipboard-desktop'))
parser.add_argument('--applications-dir', default=str(xdg('XDG_DATA_HOME', '.local/share') / 'applications'))
parser.add_argument('--bin-dir', default=str(Path.home() / '.local/bin'))
parser.add_argument('--config-home', default=str(xdg('XDG_CONFIG_HOME', '.config')))
args = parser.parse_args()
source = Path(__file__).resolve().parent
value = manifest(source)
for name, expected in value['files'].items():
    file = source / name
    if not file.is_file() or file.is_symlink() or hashlib.sha256(file.read_bytes()).hexdigest() != expected:
        raise RuntimeError('Package verification failed: ' + name)
prefix = absolute(args.prefix)
applications, bin_dir, config = map(absolute, [args.applications_dir, args.bin_dir, args.config_home])
if prefix == source:
    raise RuntimeError('Choose an installation directory outside the extracted package')
entry = applications / (APP_ID + '.desktop')
shortcut = bin_dir / 'clipboard-desktop'
if entry.exists() and ('X-Clipboard-InstallRoot=' + str(prefix) + '\n') not in entry.read_text():
    raise RuntimeError('An application entry already belongs to another installation')
if shortcut.exists() or shortcut.is_symlink():
    if not shortcut.is_symlink() or shortcut.resolve() != (prefix / 'bin/ClipboardDesktop').resolve():
        raise RuntimeError('The command name already belongs to another installation')
old = None
if prefix.exists():
    installation_lock = lock_installation(prefix)
    old = manifest(prefix)
    unknown = [str(p.relative_to(prefix)) for p in prefix.rglob('*')
               if p.is_file() and str(p.relative_to(prefix)) not in owned_files(prefix, old)]
    if unknown:
        raise RuntimeError('Installation contains unmanaged files; move them before upgrading')
prefix.parent.mkdir(parents=True, exist_ok=True)
stage = prefix.with_name(prefix.name + '.new-' + uuid.uuid4().hex)
backup = prefix.with_name(prefix.name + '.old-' + uuid.uuid4().hex)
shutil.copytree(source, stage, ignore=shutil.ignore_patterns('__pycache__'))
metadata = {'applicationID': APP_ID, 'prefix': str(prefix), 'desktopEntry': str(entry),
            'shortcut': str(shortcut), 'autostart': str(config / 'autostart' / (APP_ID + '.desktop'))}
(stage / 'installation.json').write_text(json.dumps(metadata, indent=2) + '\n')
if old:
    prefix.rename(backup)
try:
    stage.rename(prefix)
    applications.mkdir(parents=True, exist_ok=True)
    bin_dir.mkdir(parents=True, exist_ok=True)
    if shortcut.is_symlink():
        shortcut.unlink()
    shortcut.symlink_to(prefix / 'bin/ClipboardDesktop')
    icon = prefix / 'share/icons/hicolor/256x256/apps' / (APP_ID + '.png')
    entry.write_text('[Desktop Entry]\nType=Application\nName=Clipboard\nComment=Local clipboard history\nExec=' +
                     quoted_exec(prefix / 'bin/ClipboardDesktop') + '\nIcon=' + str(icon) +
                     '\nTerminal=false\nCategories=Utility;\nStartupNotify=true\nX-Clipboard-InstallRoot=' + str(prefix) + '\n')
except Exception:
    remove_managed(prefix, value)
    if old:
        backup.rename(prefix)
    raise
if old:
    remove_managed(backup, old)
print('Installed Clipboard Desktop ' + value['version'] + ' in ' + str(prefix))
print('History and credentials are preserved. Start Clipboard from the application menu.')
