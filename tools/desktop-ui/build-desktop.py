#!/usr/bin/env python3
"""Build the pinned SwiftCrossUI package with its reviewed Windows GTK type fix."""
import argparse
import json
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--configuration', choices=['debug', 'release'], default='debug')
parser.add_argument('--scratch-path')
parser.add_argument('--cache-path')
parser.add_argument('--jobs', default='2')
args = parser.parse_args()
repo = Path(__file__).resolve().parents[2]
package = repo / 'Desktop'
common = ['--package-path', str(package)]
if args.scratch_path:
    common += ['--scratch-path', args.scratch_path]
if args.cache_path:
    common += ['--cache-path', args.cache_path]
subprocess.run(['swift', 'package'] + common + ['resolve'], check=True)
build = Path(args.scratch_path).resolve() if args.scratch_path else package / '.build'
checkout = build / 'checkouts/swift-cross-ui'
pin = next(p for p in json.loads((package / 'Package.resolved').read_text())['pins'] if p['identity'] == 'swift-cross-ui')
revision = subprocess.check_output(['git', '-C', str(checkout), 'rev-parse', 'HEAD'], text=True).strip()
if pin['state'].get('version') != '0.10.0' or revision != pin['state']['revision']:
    raise RuntimeError('The GTK portability patch requires the pinned SwiftCrossUI 0.10.0 revision')
patch = package / 'Patches/swift-cross-ui-0.10.0-gtk-windows.patch'
reversed = subprocess.run(['git', '-C', str(checkout), 'apply', '--reverse', '--check', str(patch)], capture_output=True)
if reversed.returncode != 0:
    subprocess.run(['git', '-C', str(checkout), 'apply', '--check', str(patch)], check=True)
    subprocess.run(['git', '-C', str(checkout), 'apply', str(patch)], check=True)
print('Applied pinned GTK C integer-width compatibility patch', flush=True)
subprocess.run(['swift', 'build'] + common + ['--configuration', args.configuration, '--jobs', args.jobs,
                                            '--product', 'ClipboardDesktop'], check=True)
