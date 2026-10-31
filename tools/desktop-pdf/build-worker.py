#!/usr/bin/env python3
"""Build the private PDF worker with a hash-pinned, non-V8 PDFium runtime."""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

REVISION = 'chromium/8125'
# Digests published by the immutable release's asset metadata:
# https://github.com/bblanchon/pdfium-binaries/releases/expanded_assets/chromium/8125
DIGESTS = {
    'linux-arm64': '8b8818f2ec57d1b213d952ca6d7f0ffeca9d0110487d0e20ad83ba918bc92efa',
    'linux-x64': 'e1c3ce6e270cb5e0c20816b379ad9f2c1309972697c505f508de92bf5e7d6659',
    'win-x64': '9a964261760cff52570aabf038ab346d3a5034dd8b30d0d5fe8861235d356b8b',
}
parser = argparse.ArgumentParser()
parser.add_argument('--output', required=True)
parser.add_argument('--cache', required=True, help='Verified SDK archive cache, not a runtime search path')
args = parser.parse_args()
target = ('win' if os.name == 'nt' else 'linux') + '-' + (
    'x64' if platform.machine().lower() in ('x86_64', 'amd64') else 'arm64')
if platform.system() not in ('Linux', 'Windows') or target not in DIGESTS:
    raise RuntimeError('Unsupported native PDF worker builder')
output, cache = Path(args.output).resolve(), Path(args.cache).resolve()
output.mkdir(parents=True, exist_ok=True)
cache.mkdir(parents=True, exist_ok=True)
archive = cache / ('pdfium-' + target + '.tgz')
url = 'https://github.com/bblanchon/pdfium-binaries/releases/download/chromium%2F8125/' + archive.name
if not archive.exists():
    with urllib.request.urlopen(url, timeout=45) as response:
        content = response.read(10 * 1024 * 1024 + 1)
    if hashlib.sha256(content).hexdigest() != DIGESTS[target]:
        raise RuntimeError('PDFium archive checksum mismatch')
    with tempfile.NamedTemporaryFile(dir=cache, delete=False) as pending:
        pending.write(content)
        pending_path = Path(pending.name)
    pending_path.replace(archive)
with archive.open('rb') as file:
    archive_data = file.read(10 * 1024 * 1024 + 1)
if len(archive_data) > 10 * 1024 * 1024 or hashlib.sha256(archive_data).hexdigest() != DIGESTS[target]:
    raise RuntimeError('PDFium cached archive checksum mismatch')

with tempfile.TemporaryDirectory(prefix='pdf-worker-', dir=output) as temporary:
    stage = Path(temporary)
    sdk = stage / 'sdk'
    sdk.mkdir()
    with tarfile.open(fileobj=io.BytesIO(archive_data), mode='r:gz') as source:
        for entry in source:
            destination = (sdk / entry.name).resolve()
            if not destination.is_relative_to(sdk) or not (entry.isdir() or entry.isfile()):
                raise RuntimeError('Unsafe PDFium SDK archive entry')
            if entry.isfile():
                destination.parent.mkdir(parents=True, exist_ok=True)
                with source.extractfile(entry) as data, destination.open('wb') as file:
                    shutil.copyfileobj(data, file)
    library = sdk / ('bin/pdfium.dll' if os.name == 'nt' else 'lib/libpdfium.so')
    worker_name = 'clipboard-pdf-worker' + ('.exe' if os.name == 'nt' else '')
    compiler = shutil.which('clang') or shutil.which('cc')
    if not compiler:
        raise RuntimeError('Native C compiler required for the PDF worker')
    command = [compiler, '-O2', '-I', str(sdk / 'include'), str(Path(__file__).resolve().with_name('pdf-text-worker.c'))]
    if os.name == 'nt':
        command += [str(sdk / 'lib/pdfium.dll.lib'), '-Xlinker', '/SUBSYSTEM:WINDOWS', '-Xlinker', '/ENTRY:mainCRTStartup']
    else:
        command += ['-L', str(sdk / 'lib'), '-lpdfium', '-Wl,-rpath,$ORIGIN']
    subprocess.run(command + ['-o', str(stage / worker_name)], check=True, cwd=stage, timeout=120)
    shutil.copy2(library, stage / library.name)
    notices = output / 'pdfium-notices'
    notices.mkdir(exist_ok=True)
    for name in ['LICENSE', 'VERSION', 'args.gn']:
        shutil.copy2(sdk / name, notices / name)
    shutil.copytree(sdk / 'licenses', notices / 'licenses', dirs_exist_ok=True)
    provenance = {'revision': REVISION, 'asset': archive.name, 'sha256': DIGESTS[target],
                  'download': url, 'upstream': 'https://pdfium.googlesource.com/pdfium/',
                  'builder': 'https://github.com/bblanchon/pdfium-binaries/tree/chromium/8125',
                  'javascript': False, 'xfa': False}
    (notices / 'provenance.json').write_text(json.dumps(provenance, indent=2) + '\n')
    for name in [worker_name, library.name]:
        (stage / name).replace(output / name)
print('Built bounded native PDF worker and verified runtime/notices', flush=True)
