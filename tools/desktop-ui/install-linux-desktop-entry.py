#!/usr/bin/env python3
"""Install application identity for an explicitly selected Linux development build."""
import argparse
import os
from pathlib import Path

APP_ID = 'com.clipboard.desktop'


def entry_for(executable):
    path = Path(executable).expanduser().resolve(strict=True)
    if not path.is_file() or not os.access(path, os.X_OK):
        raise ValueError('Choose an executable development build')
    text = str(path)
    if any(character in text for character in ('\n', '\r', '\0', '=', '%')):
        raise ValueError('The executable path cannot be represented by a desktop entry')
    # Exec quoting is decoded after desktop string escaping. Preserve both layers.
    for character in ['\\', '"', '$', '`']:
        text = text.replace(character, '\\' + character)
    text = text.replace('\\', '\\\\').replace('\t', '\\t')
    return ('[Desktop Entry]\nType=Application\nName=Clipboard\n'
            'Comment=Local clipboard history\nExec="' + text + '"\n'
            'Icon=' + str(Path(__file__).resolve().parents[2] / 'Desktop/Sources/ClipboardDesktop/Resources/icons/com.clipboard.desktop.png').replace('\\', '\\\\') + '\nTerminal=false\nCategories=Utility;\nStartupNotify=true\nStartupWMClass=ClipboardDesktop\n'
            'X-Clipboard-DevelopmentEntry=true\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--executable', required=True)
    args = parser.parse_args()
    content = entry_for(args.executable)
    hint = os.environ.get('XDG_DATA_HOME', '')
    data = Path(hint) if hint and Path(hint).is_absolute() else Path.home() / '.local/share'
    entry = data / 'applications' / (APP_ID + '.desktop')
    if entry.is_symlink():
        raise RuntimeError('Refusing a symbolic-link application entry')
    if entry.exists():
        if entry.read_text(encoding='utf-8') != content:
            raise RuntimeError('An application entry already exists; keep its installation or explicitly remove it before registering this development build')
        return
    entry.parent.mkdir(parents=True, exist_ok=True)
    # Exclusive creation cannot overwrite an existing package/other user's entry.
    with entry.open('x', encoding='utf-8') as output:
        output.write(content)
    print('Registered Clipboard development application identity')


if __name__ == '__main__':
    main()
