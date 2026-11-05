#!/usr/bin/env python3
"""Build the pinned SwiftCrossUI package with its reviewed Windows GTK type fix."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys

parser = argparse.ArgumentParser()
parser.add_argument('--configuration', choices=['debug', 'release'], default='debug')
parser.add_argument('--scratch-path')
parser.add_argument('--cache-path')
parser.add_argument('--jobs', default='2')
args = parser.parse_args()
repo = Path(__file__).resolve().parents[2]
package = repo / 'Desktop'
for manifest, notice, resource in [('desktop-language', 'model-LICENSE', 'Apache-2.0.txt'),
                                   ('desktop-text', 'AFL-3.0.txt', 'AFL-3.0.txt')]:
    pins = json.loads((repo / ('tools/' + manifest + '/upstream.json')).read_text())
    pin = next(value for value in pins['notices'] if value['name'] == notice)
    data = (package / 'Sources/ClipboardDesktop/Resources/ModelLicenses' / resource).read_bytes()
    if len(data) != pin['size'] or hashlib.sha256(data).hexdigest() != pin['sha256']:
        raise RuntimeError('Bundled model license must match its fixed upstream notice')
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
for patch in sorted((package / 'Patches').glob('swift-cross-ui-0.10.0-*.patch')):
    reversed = subprocess.run(['git', '-C', str(checkout), 'apply', '--reverse', '--check', str(patch)], capture_output=True)
    if reversed.returncode != 0:
        subprocess.run(['git', '-C', str(checkout), 'apply', '--check', str(patch)], check=True)
        subprocess.run(['git', '-C', str(checkout), 'apply', str(patch)], check=True)
    print('Applied pinned GTK compatibility patch: ' + patch.name, flush=True)
link_flags = []
if sys.platform == 'win32':
    icon = package / 'Packaging/clipboard.ico'
    # Include the icon digest in the linker input so incremental builds relink on changes.
    resources = build / 'application-icons' / hashlib.sha256(icon.read_bytes()).hexdigest()
    resources.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(icon, resources / 'clipboard.ico')
    (resources / 'clipboard.rc').write_text('101 ICON "clipboard.ico"\n', encoding='ascii')
    compiler = shutil.which('rc.exe') or shutil.which('llvm-rc.exe')
    if not compiler:
        raise RuntimeError('Windows SDK or LLVM resource compiler required')
    subprocess.run([compiler, '/FO', 'clipboard.res', 'clipboard.rc'], cwd=resources, check=True)
    link_flags = ['-Xlinker', str(resources / 'clipboard.res')]
subprocess.run(['swift', 'build'] + common + link_flags + ['--configuration', args.configuration, '--jobs', args.jobs,
                                            '--product', 'ClipboardDesktop'], check=True)
binary_dir = subprocess.check_output(['swift', 'build'] + common + [
    '--configuration', args.configuration, '--show-bin-path'], text=True).strip()
subprocess.run([sys.executable,
                str(repo / 'tools/desktop-pdf/build-worker.py'), '--output', binary_dir,
                '--cache', str((Path(args.cache_path).resolve() if args.cache_path else build) / 'pdfium-sdk-8125')],
               check=True)
subprocess.run([sys.executable, str(repo / 'tools/desktop-pdf/check-worker.py'),
                '--executable', str(Path(binary_dir) / (
                    'clipboard-pdf-worker.exe' if sys.platform == 'win32' else 'clipboard-pdf-worker'))], check=True)
subprocess.run([sys.executable, str(repo / 'tools/desktop-image/build-worker.py'), '--output', binary_dir,
                '--cache', str((Path(args.cache_path).resolve() if args.cache_path else build) / 'local-image-sdk-1.31.1')],
               check=True)
subprocess.run([sys.executable, str(repo / 'tools/desktop-image/check-worker.py'),
                '--executable', str(Path(binary_dir) / (
                    'clipboard-image-worker.exe' if sys.platform == 'win32' else 'clipboard-image-worker'))], check=True)
for component, cache_name in [('desktop-language', 'local-language-sdk'), ('desktop-text', 'local-text-sdk')]:
    subprocess.run([sys.executable, str(repo / ('tools/' + component + '/build-worker.py')),
                    '--output', binary_dir,
                    '--cache', str((Path(args.cache_path).resolve() if args.cache_path else build) / cache_name)],
                   check=True)
# Normal application builds never request optional summary/entity weights.
subprocess.run([sys.executable, str(repo / 'tools/desktop-ui/check-local-model-runtime.py'),
                '--directory', binary_dir], check=True)
