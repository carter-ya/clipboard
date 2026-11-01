#!/usr/bin/env python3
"""Apply the reviewed patch to LF archive sources, regardless of Git checkout EOL."""
from pathlib import Path
import subprocess
import sys

source, patch = Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve()
# Windows Git may check out patches with CRLF while the verified GTK tar archive
# contains LF. Normalize only the patch input, never arbitrary source contents.
data = patch.read_text(encoding='utf-8').encode('utf-8')
command = ['git', '-C', str(source), 'apply']
if subprocess.run(command + ['--reverse', '--check', '-'], input=data, capture_output=True).returncode != 0:
    subprocess.run(command + ['--check', '-'], input=data, check=True)
    subprocess.run(command + ['-'], input=data, check=True)
print('Applied reviewed GTK AccessKit action patch', flush=True)
