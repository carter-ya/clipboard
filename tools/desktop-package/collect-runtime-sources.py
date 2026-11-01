#!/usr/bin/env python3
"""Collect hash-verified GTK sources and the exact runtime build recipes."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import venv

GVSBUILD = '0362fd8b198f535b8ae7b6d59a86834ca7069b34'
ACCESSKIT = '0c52a8ce2357bbeb927f90dc9a1c19c8ec1bd2c3'
parser = argparse.ArgumentParser()
parser.add_argument('--workdir', required=True)
parser.add_argument('--output', required=True)
args = parser.parse_args()
work, output = Path(args.workdir).resolve(), Path(args.output).resolve()
work.mkdir(parents=True, exist_ok=True)
output.mkdir(parents=True, exist_ok=True)
repo = Path(__file__).resolve().parents[2]


def checkout(name, url, revision):
    root = work / name
    if not root.exists():
        subprocess.run(['git', 'init', str(root)], check=True, capture_output=True)
        subprocess.run(['git', '-C', str(root), 'remote', 'add', 'origin', url], check=True)
        subprocess.run(['git', '-C', str(root), '-c', 'http.lowSpeedLimit=1024', '-c', 'http.lowSpeedTime=120',
                        'fetch', '--depth', '1', 'origin', revision], check=True, timeout=180)
        subprocess.run(['git', '-C', str(root), 'checkout', '--detach', 'FETCH_HEAD'], check=True, capture_output=True)
    actual = subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip()
    if actual != revision:
        raise RuntimeError('Unexpected source checkout revision: ' + name)
    return root


gvsbuild = checkout('gvsbuild', 'https://github.com/wingtk/gvsbuild.git', GVSBUILD)
accesskit = checkout('accesskit-c', 'https://github.com/AccessKit/accesskit-c.git', ACCESSKIT)
environment = work / 'python-env'
if not environment.exists():
    venv.EnvBuilder(with_pip=True).create(environment)
python = environment / ('Scripts/python.exe' if os.name == 'nt' else 'bin/python')
cli = environment / ('Scripts/gvsbuild.exe' if os.name == 'nt' else 'bin/gvsbuild')
log = work / 'fetch.log'
with log.open('w') as progress:
    subprocess.run([str(python), '-m', 'pip', 'install', str(gvsbuild)], check=True, stdout=progress,
                   stderr=subprocess.STDOUT, timeout=180)
    print('Fetching and verifying pinned GTK dependency source archives', flush=True)
    subprocess.run([str(cli), 'build', '--fetch-only', '--build-dir', str(work / 'build'),
                    '--archives-download-dir', str(work / 'archives'), '--export-dir', str(work / 'export'),
                    'gtk4', 'adwaita-icon-theme'], check=True, stdout=progress, stderr=subprocess.STDOUT, timeout=900)
root = work / 'source-package'
root.mkdir(exist_ok=True)
archives = root / 'archives'
archives.mkdir(exist_ok=True)
# Runtime library source archives; omit unused prebuilt build-tool ZIP/EXE files.
for source in (work / 'archives').iterdir():
    if source.is_file() and source.name.endswith(('.tar.gz', '.tar.xz', '.tar.bz2', '.tgz')):
        shutil.copy2(source, archives / source.name)
for name, source, revision in [('gvsbuild', gvsbuild, GVSBUILD), ('accesskit-c', accesskit, ACCESSKIT)]:
    with (archives / (name + '-' + revision + '.tar.gz')).open('wb') as target:
        subprocess.run(['git', '-C', str(source), 'archive', '--format=tar.gz', '--prefix=' + name + '/', revision],
                       stdout=target, check=True)
recipes = root / 'clipboard-build-recipes'
recipes.mkdir(exist_ok=True)
for name in ['install-windows-gtk.ps1', 'extract-gtk-source.py', 'normalize-windows-pkgconfig.py', 'gtk-4.22.4-accesskit-actions.patch', 'apply-gtk-source-patch.py']:
    shutil.copy2(repo / 'tools/desktop-ui' / name, recipes / name)
manifest = {'gvsbuildCommit': GVSBUILD, 'accesskitCommit': ACCESSKIT, 'gtkVersion': '4.22.4', 'files': {}}
for file in sorted(root.rglob('*')):
    if file.is_file() and file.name != 'source-manifest.json':
        manifest['files'][str(file.relative_to(root)).replace('\\', '/')] = hashlib.sha256(file.read_bytes()).hexdigest()
(root / 'source-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
archive = output / 'ClipboardDesktop-third-party-sources-gtk4.22.4.tar.gz'
with tarfile.open(archive, 'w:gz') as tar:
    tar.add(root, arcname='ClipboardDesktop-third-party-sources')
(output / 'SHA256SUMS').write_text(hashlib.sha256(archive.read_bytes()).hexdigest() + '  ' + archive.name + '\n')
print('Collected source and recipe files: ' + str(len(manifest['files'])), flush=True)
print(str(archive), flush=True)
