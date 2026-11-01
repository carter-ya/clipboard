"""Shared metadata and desktop-entry handling for this application's own files."""
import json
import os
from pathlib import Path

APP_ID = 'com.clipboard.desktop'


def manifest(root):
    value = json.loads((root / 'package-manifest.json').read_text())
    if value.get('applicationID') != APP_ID:
        raise RuntimeError('This directory is not a Clipboard Desktop package')
    for name in value['files']:
        relative = Path(name)
        if relative.is_absolute() or '..' in relative.parts:
            raise RuntimeError('Invalid package manifest path')
    return value


def absolute(value):
    path = Path(value).expanduser().resolve()
    if not path.is_absolute() or path == Path('/') or len(path.parts) < 3:
        raise RuntimeError('Choose an absolute application directory')
    return path


def xdg(name, fallback):
    value = os.environ.get(name)
    return Path(value) if value and Path(value).is_absolute() else Path.home() / fallback


def quoted_exec(path):
    text = str(path)
    if any(char in text for char in ('\n', '\r', '\0')):
        raise RuntimeError('Invalid desktop entry path')
    for character in ['\\', '"', '$', '`']:
        text = text.replace(character, '\\' + character)
    return '"' + text.replace('%', '%%') + '"'


def owned_files(root, value):
    return set(value['files']) | {'package-manifest.json', 'installation.json'}


def remove_managed(root, value):
    for name in owned_files(root, value):
        file = root / name
        if file.is_file() or file.is_symlink():
            file.unlink()
    for directory in sorted((p for p in root.rglob('*') if p.is_dir() and not p.is_symlink()),
                            key=lambda p: len(p.parts), reverse=True):
        try:
            directory.rmdir()
        except OSError:
            pass
    try:
        root.rmdir()
    except OSError:
        pass


def lock_installation(root):
    import fcntl
    fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        os.close(fd)
        raise RuntimeError('Quit Clipboard before upgrading or uninstalling this installation') from None
    return fd
