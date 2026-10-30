#!/usr/bin/env python3
"""Preserve .pc paths while avoiding SwiftPM 6.3's colon-before-equals parser bug."""
import argparse
import ntpath
from pathlib import Path
import re

parser = argparse.ArgumentParser()
parser.add_argument('--prefix', required=True)
args = parser.parse_args()
prefix = Path(args.prefix)
changed = 0
for directory in [prefix / 'lib/pkgconfig', prefix / 'share/pkgconfig']:
    for file in directory.glob('*.pc'):
        original = file.read_text(encoding='utf-8')
        lines = []
        for line in original.splitlines():
            match = re.fullmatch(r'([A-Za-z_][A-Za-z_0-9]*)\s*=\s*([A-Za-z]:[/\\].*)', line)
            if match:
                relative = ntpath.relpath(match[2], str(file.parent)).replace('\\', '/')
                line = match[1] + '=${pcfiledir}/' + relative
            lines.append(line)
        normalized = '\n'.join(lines) + '\n'
        if normalized != original:
            file.write_text(normalized, encoding='utf-8')
            changed += 1
print('Normalized Windows pkg-config files: ' + str(changed), flush=True)
