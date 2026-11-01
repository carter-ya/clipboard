#!/usr/bin/env python3
"""Build the pinned CPU worker. Never install weights into an application.

--download-test-model explicitly obtains public weights for development/CI;
normal builds download only the SDK and attribution notices.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def write_changed(path, data):
    if path.is_symlink() or (path.exists() and not path.is_file()):
        raise RuntimeError('Unsafe language build cache entry')
    if not path.exists() or path.read_bytes() != data:
        path.write_bytes(data)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True)
    parser.add_argument('--cache', required=True)
    parser.add_argument('--download-test-model', action='store_true')
    args = parser.parse_args()
    system, machine = platform.system(), platform.machine().lower()
    if (system not in ('Windows', 'Linux') or machine not in ('amd64', 'x86_64', 'arm64', 'aarch64') or
            (system == 'Windows' and machine not in ('amd64', 'x86_64'))):
        raise RuntimeError('Language worker requires a native Windows/Linux builder')
    source = Path(__file__).resolve().parent
    repo = source.parents[1]
    pins = json.loads((source / 'upstream.json').read_text())
    model = json.loads((repo / pins['modelManifest']).read_text())
    if (not re.fullmatch(r'[0-9a-f]{40}', pins['commit']) or
            pins['sourceURL'] != 'https://codeload.github.com/ggml-org/llama.cpp/tar.gz/' + pins['commit'] or
            not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', model['repository']) or
            not re.fullmatch(r'[0-9a-f]{40}', model['revision']) or
            not re.fullmatch(r'[A-Za-z0-9_-][A-Za-z0-9_.-]*\.gguf', model['filename']) or
            model['url'] != 'https://huggingface.co/' + model['repository'] + '/resolve/' + model['revision'] + '/' + model['filename'] or
            not re.fullmatch(r'[0-9a-f]{64}', model['sha256']) or
            not 0 < model['size'] <= 8 * 1024**3):
        raise RuntimeError('Invalid pinned language metadata')
    cache = Path(args.cache).absolute()
    output = Path(args.output).absolute()
    for directory in (cache, output):
        if directory.is_symlink():
            raise RuntimeError('Unsafe language build directory')
        directory.mkdir(parents=True, exist_ok=True)
    cache, output = cache.resolve(), output.resolve()

    def verified(url, name, size, expected):
        if not re.fullmatch(r'[A-Za-z0-9_.-]+', name) or not re.fullmatch(r'[0-9a-f]{64}', expected):
            raise RuntimeError('Invalid language dependency pin')
        path = cache / (expected[:16] + '-' + name)
        if path.is_symlink() or (path.exists() and not path.is_file()):
            raise RuntimeError('Unsafe cached language dependency')
        if path.exists():
            if path.stat().st_size != size or digest(path) != expected:
                raise RuntimeError('Cached language dependency failed verification')
            return path
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(dir=cache, delete=False) as stream:
                temporary = Path(stream.name)
                checksum, total = hashlib.sha256(), 0
                with urllib.request.urlopen(url, timeout=60) as response:
                    while block := response.read(1024 * 1024):
                        total += len(block)
                        if total > size:
                            raise RuntimeError('Language dependency exceeded its fixed size')
                        checksum.update(block)
                        stream.write(block)
            if total != size or checksum.hexdigest() != expected:
                raise RuntimeError('Language dependency download failed verification')
            temporary.replace(path)
            return path
        finally:
            if temporary is not None:
                temporary.unlink(missing_ok=True)

    archive = verified(pins['sourceURL'], 'llama-' + pins['commit'][:7] + '.tar.gz',
                       pins['sourceSize'], pins['sourceSHA256'])
    sdk = cache / ('source-' + pins['commit'])
    if sdk.is_symlink():
        raise RuntimeError('Unsafe cached language SDK')
    sdk.mkdir(exist_ok=True)
    prefix = 'llama.cpp-' + pins['commit'] + '/'
    # Revalidate every source file against the verified archive on cache hits.
    # Keep unchanged mtimes so a cached native build remains incremental.
    with tarfile.open(archive, mode='r:gz') as bundle:
        total = 0
        for entry in bundle:
            if entry.isdir():
                continue
            if not entry.name.startswith(prefix) or not entry.isfile() or entry.size > 64 * 1024**2:
                raise RuntimeError('Invalid language SDK archive entry')
            relative = PurePosixPath(entry.name[len(prefix):])
            if relative.is_absolute() or '..' in relative.parts or '\\' in entry.name:
                raise RuntimeError('Unsafe language SDK archive path')
            total += entry.size
            if total > 256 * 1024**2:
                raise RuntimeError('Language SDK extraction budget exceeded')
            target = sdk.joinpath(*relative.parts)
            for parent in target.parents:
                if parent == sdk:
                    break
                if parent.is_symlink():
                    raise RuntimeError('Unsafe language SDK cache directory')
            target.parent.mkdir(parents=True, exist_ok=True)
            data = bundle.extractfile(entry).read(entry.size + 1)
            if len(data) != entry.size:
                raise RuntimeError('Invalid language SDK entry length')
            write_changed(target, data)

    project = cache / ('worker-' + pins['commit'][:12] + '-' + model['sha256'][:12])
    if project.is_symlink():
        raise RuntimeError('Unsafe language worker project')
    project.mkdir(exist_ok=True)
    for name in ('CMakeLists.txt', 'language-worker.cpp', 'model-cpu.h', 'cpu-check.cpp'):
        write_changed(project / name, (source / name).read_bytes())
    header = ('#include <cstdint>\nstatic constexpr uint64_t model_size = ' + str(model['size']) + 'ULL;\n'
              'static const unsigned char model_sha256[32] = {' +
              ','.join('0x' + model['sha256'][index:index + 2] for index in range(0, 64, 2)) + '};\n')
    write_changed(project / 'model-pin.h', header.encode('ascii'))
    build = project / 'build'
    if build.is_symlink():
        raise RuntimeError('Unsafe language worker build directory')
    command = ['cmake', '-S', str(project), '-B', str(build), '-DCMAKE_BUILD_TYPE=Release',
               '-DLLAMA_SOURCE=' + sdk.as_posix(), '-DMODEL_INCLUDE=' + project.as_posix()]
    for name, arguments in (
            ('language-configure.log', command),
            ('language-build.log', ['cmake', '--build', str(build), '--config', 'Release',
                                    '--target', 'clipboard-language-worker', 'language-cpu-check', '--parallel', '2'])):
        with (output / name).open('wb') as log:
            subprocess.run(arguments, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=900)
    name = 'clipboard-language-worker' + ('.exe' if os.name == 'nt' else '')
    subprocess.run([str(build / 'bin' / ('language-cpu-check' + ('.exe' if os.name == 'nt' else '')))],
                   check=True, timeout=10)
    notices = output / 'language-model-notices'
    if notices.is_symlink():
        raise RuntimeError('Unsafe language notices directory')
    notices.mkdir(exist_ok=True)
    for relative in ('LICENSE', 'licenses/LICENSE-jsonhpp', 'vendor/hash/sha256/LICENSE',
                     'vendor/hash/rotate-bits/LICENSE.md'):
        write_changed(notices / relative.replace('/', '-'), (sdk / relative).read_bytes())
    for value in pins['notices']:
        path = verified(value['url'], value['name'], value['size'], value['sha256'])
        write_changed(notices / value['name'], path.read_bytes())
    shutil.copy2(build / 'bin' / name, output / name)
    provenance = {'sdk': pins, 'model': model, 'cpuOnly': True, 'weightsBundled': False,
                  'sdkArchiveVerified': True, 'inferenceVerified': False}
    if args.download_test_model:
        path = verified(model['url'], model['filename'], model['size'], model['sha256'])
        subprocess.run([os.sys.executable, str(source / 'check-worker.py'),
                        '--executable', str(output / name), '--model', str(path)], check=True, timeout=300)
        provenance['inferenceVerified'] = True
    write_changed(notices / 'provenance.json', (json.dumps(provenance, indent=2) + '\n').encode())
    print('Built verified CPU language worker and notices; model weights remain separate', flush=True)


if __name__ == '__main__':
    try:
        main()
    except Exception:
        # Redirects can contain signed URLs. Never expose network exception text.
        raise SystemExit('Language worker build/verification failed; inspect the bounded build logs')
