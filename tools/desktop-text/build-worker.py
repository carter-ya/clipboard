#!/usr/bin/env python3
"""Build a fixed CPU text tagger; entity weights require explicit test setup."""
import argparse
import hashlib
import io
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
import zipfile


def sha256(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def write(path, data):
    if path.is_symlink() or (path.exists() and not path.is_file()):
        raise RuntimeError('Unsafe text build entry')
    if not path.exists() or path.read_bytes() != data:
        path.write_bytes(data)


def copy_file(source, destination):
    if destination.is_symlink() or (destination.exists() and not destination.is_file()):
        raise RuntimeError('Unsafe text build output')
    shutil.copy2(source, destination)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True)
    parser.add_argument('--cache', required=True)
    parser.add_argument('--download-test-model', action='store_true')
    args = parser.parse_args()
    system, machine = platform.system(), platform.machine().lower()
    architecture = 'x64' if machine in ('amd64', 'x86_64') else 'aarch64' if machine in ('arm64', 'aarch64') else ''
    if system not in ('Linux', 'Windows') or not architecture or (system == 'Windows' and architecture != 'x64'):
        raise RuntimeError('Unsupported native text worker builder')
    source = Path(__file__).resolve().parent
    repo = source.parents[1]
    pins = json.loads((source / 'upstream.json').read_text())
    runtime_pins = json.loads((repo / pins['onnxRuntimeManifest']).read_text())
    unicode_pins = json.loads((repo / pins['unicodeSourceManifest']).read_text())
    entity = json.loads((repo / pins['entityManifest']).read_text())
    if (entity['license'] != 'AFL-3.0' or entity['licenseAcceptanceRequired'] is not True or
            not re.fullmatch(r'[0-9a-f]{40}', entity['revision']) or
            not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', entity['repository']) or
            not re.fullmatch(r'[A-Za-z0-9_-][A-Za-z0-9_.-]*\.onnx', entity['filename']) or
            entity['url'] != 'https://huggingface.co/' + entity['repository'] + '/resolve/' + entity['revision'] + '/onnx/' + entity['filename']):
        raise RuntimeError('Invalid fixed entity metadata')
    cache, output = Path(args.cache).absolute(), Path(args.output).absolute()
    for directory in (cache, output):
        if directory.is_symlink():
            raise RuntimeError('Unsafe text build directory')
        directory.mkdir(parents=True, exist_ok=True)
    cache, output = cache.resolve(), output.resolve()

    def verified(value):
        name, size, expected = value['name'], value['size'], value['sha256']
        if (not re.fullmatch(r'[A-Za-z0-9_.-]+', name) or not re.fullmatch(r'[0-9a-f]{64}', expected) or
                not 0 < size <= 2 * 1024**3):
            raise RuntimeError('Invalid text dependency pin')
        path = cache / (expected[:16] + '-' + name)
        if path.is_symlink() or (path.exists() and not path.is_file()):
            raise RuntimeError('Unsafe cached text dependency')
        if path.exists():
            if path.stat().st_size != size or sha256(path) != expected:
                raise RuntimeError('Cached text dependency failed verification')
            return path
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(dir=cache, delete=False) as stream:
                temporary = Path(stream.name)
                checksum, total = hashlib.sha256(), 0
                with urllib.request.urlopen(value['url'], timeout=60) as response:
                    while block := response.read(1024 * 1024):
                        total += len(block)
                        if total > size:
                            raise RuntimeError('Text dependency size exceeded')
                        checksum.update(block)
                        stream.write(block)
            if total != size or checksum.hexdigest() != expected:
                raise RuntimeError('Text dependency download failed verification')
            temporary.replace(path)
            return path
        finally:
            if temporary is not None:
                temporary.unlink(missing_ok=True)

    def extract(archive, target, prefix, selected):
        if target.is_symlink():
            raise RuntimeError('Unsafe text SDK directory')
        target.mkdir(exist_ok=True)
        members = []
        if archive.suffix == '.zip':
            with zipfile.ZipFile(archive) as bundle:
                for member in bundle.infolist():
                    if member.is_dir() or not member.filename.startswith(prefix):
                        continue
                    relative = member.filename[len(prefix):]
                    if not selected(relative):
                        continue
                    if member.file_size > 64 * 1024**2 or (member.external_attr >> 16) & 0o170000 == 0o120000:
                        raise RuntimeError('Invalid text SDK zip entry')
                    members.append((relative, bundle.read(member)))
        else:
            with tarfile.open(archive, mode='r:gz') as bundle:
                for member in bundle:
                    if member.isdir() or not member.name.startswith(prefix):
                        continue
                    relative = member.name[len(prefix):]
                    if not selected(relative):
                        continue
                    if not member.isfile() or member.size > 64 * 1024**2:
                        raise RuntimeError('Invalid text SDK tar entry')
                    data = bundle.extractfile(member).read(member.size + 1)
                    if len(data) != member.size:
                        raise RuntimeError('Invalid text SDK entry length')
                    members.append((relative, data))
        if sum(len(data) for _, data in members) > 128 * 1024**2:
            raise RuntimeError('Text SDK extraction budget exceeded')
        for relative, data in members:
            path = PurePosixPath(relative)
            if path.is_absolute() or '..' in path.parts or '\\' in relative:
                raise RuntimeError('Unsafe text SDK archive path')
            destination = target.joinpath(*path.parts)
            for parent in destination.parents:
                if parent == target:
                    break
                if parent.is_symlink():
                    raise RuntimeError('Unsafe text SDK cache path')
            destination.parent.mkdir(parents=True, exist_ok=True)
            write(destination, data)
        return target

    fasttext = extract(verified(pins['fastTextSource']), cache / ('fasttext-' + pins['fastTextCommit']),
                       'fastText-' + pins['fastTextCommit'] + '/', lambda name: name.startswith('src/') or name == 'LICENSE')
    unicode_value = {'name': 'llama-' + unicode_pins['commit'][:7] + '.tar.gz', 'size': unicode_pins['sourceSize'],
                     'sha256': unicode_pins['sourceSHA256'], 'url': unicode_pins['sourceURL']}
    unicode = extract(verified(unicode_value), cache / ('unicode-' + unicode_pins['commit']),
                      'llama.cpp-' + unicode_pins['commit'] + '/',
                      lambda name: name.startswith('src/unicode') or name.startswith('vendor/hash/') or
                      name.startswith('vendor/nlohmann/') or name in ('LICENSE', 'licenses/LICENSE-jsonhpp'))
    runtime_name = 'onnxruntime-' + ('win' if system == 'Windows' else 'linux') + '-' + architecture + '-1.31.1'
    runtime_value = next(value for value in runtime_pins['assets'] if value['name'] == runtime_name + ('.zip' if system == 'Windows' else '.tgz'))
    libraries = ['lib/onnxruntime.dll', 'lib/onnxruntime.lib', 'lib/onnxruntime_providers_shared.dll'] if system == 'Windows' else ['lib/libonnxruntime.so.1.31.1']
    runtime = extract(verified(runtime_value), cache / runtime_name, runtime_name + '/',
                      lambda name: name.startswith('include/') or name in libraries + ['LICENSE', 'ThirdPartyNotices.txt'])
    language_model = verified(pins['languageModel'])
    vocabulary = verified(pins['vocabulary'])
    script = verified(pins['scriptData'])
    metadata = {value['name']: verified(value) for value in pins['entityMetadata']}
    tokenizer = json.loads(metadata['tokenizer.json'].read_text(encoding='utf-8'))
    configuration = json.loads(metadata['config.json'].read_text(encoding='utf-8'))
    if (tokenizer['normalizer'] != {'type': 'BertNormalizer', 'clean_text': True, 'handle_chinese_chars': True, 'strip_accents': None, 'lowercase': False} or
            tokenizer['pre_tokenizer'] != {'type': 'BertPreTokenizer'} or tokenizer['model']['type'] != 'WordPiece' or
            tokenizer['model']['max_input_chars_per_word'] != 100 or
            configuration['id2label'] != {str(i): label for i, label in enumerate(pins['entityModelDistribution']['runtimeClassMap'])}):
        raise RuntimeError('Pinned tokenizer/class map changed')
    project = cache / ('text-project-' + pins['fastTextCommit'][:12])
    if project.is_symlink():
        raise RuntimeError('Unsafe text worker project')
    project.mkdir(exist_ok=True)
    for name in ('CMakeLists.txt', 'text-worker.cpp', 'text-tokenizer.h', 'tokenizer-probe.cpp'):
        write(project / name, (source / name).read_bytes())
    header = '#include <cstddef>\n'
    for name, value in [('entity', entity), ('language', pins['languageModel']), ('vocabulary', pins['vocabulary'])]:
        header += 'static constexpr size_t ' + name + '_size = ' + str(value['size']) + ';\n'
        header += 'static const unsigned char ' + name + '_sha256[32] = {' + ','.join('0x' + value['sha256'][i:i + 2] for i in range(0, 64, 2)) + '};\n'
    write(project / 'text-pins.h', header.encode('ascii'))
    left, right = set(), set()
    for line in script.read_text(encoding='utf-8').splitlines():
        fields = line.split('\t')
        if len(fields) != 2 or len(fields[0]) != 1:
            raise RuntimeError('Invalid script character data')
        for value in fields[1].split():
            if len(value) != 1:
                raise RuntimeError('Invalid script character mapping')
            if value != fields[0]:
                left.add(ord(fields[0])); right.add(ord(value))
    header = '#include <cstdint>\n'
    for name, values in [('traditional_chars', left - right), ('simplified_chars', right - left)]:
        header += 'static const uint32_t ' + name + '[] = {' + ','.join(hex(value) for value in sorted(values)) + '};\n'
    write(project / 'script-characters.h', header.encode('ascii'))
    build = project / 'build'
    if build.is_symlink():
        raise RuntimeError('Unsafe text worker build directory')
    library = runtime / ('lib/onnxruntime.lib' if system == 'Windows' else 'lib/libonnxruntime.so.1.31.1')
    configure = ['cmake', '-S', str(project), '-B', str(build), '-DCMAKE_BUILD_TYPE=Release', '-DFASTTEXT_SOURCE=' + fasttext.as_posix(),
                 '-DUNICODE_SOURCE=' + unicode.as_posix(), '-DONNX_INCLUDE=' + (runtime / 'include').as_posix(), '-DONNX_LIBRARY=' + library.as_posix(),
                 '-DGENERATED_INCLUDE=' + project.as_posix()]
    for name, command in [('text-configure.log', configure), ('text-build.log', ['cmake', '--build', str(build), '--config', 'Release',
                                         '--target', 'clipboard-text-worker', 'tokenizer-reference-check', '--parallel', '2'])]:
        destination = output / name
        if destination.is_symlink() or (destination.exists() and not destination.is_file()):
            raise RuntimeError('Unsafe text build log')
        with destination.open('wb') as log:
            subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=600)
    suffix = '.exe' if system == 'Windows' else ''
    worker = output / ('clipboard-text-worker' + suffix)
    copy_file(build / 'bin' / worker.name, worker)
    copy_file(language_model, output / 'clipboard-language-id.ftz')
    copy_file(vocabulary, output / 'clipboard-text-vocab.txt')
    copy_file(runtime / ('lib/onnxruntime.dll' if system == 'Windows' else 'lib/libonnxruntime.so.1.31.1'),
                 output / ('onnxruntime.dll' if system == 'Windows' else 'libonnxruntime.so.1'))
    if system == 'Windows':
        copy_file(runtime / 'lib/onnxruntime_providers_shared.dll', output / 'onnxruntime_providers_shared.dll')
    notices = output / 'text-model-notices'
    if notices.is_symlink():
        raise RuntimeError('Unsafe text notices directory')
    notices.mkdir(exist_ok=True)
    for name, path in [('fastText-LICENSE', fasttext / 'LICENSE'), ('Unicode-SDK-LICENSE', unicode / 'LICENSE'),
                       ('sha256-LICENSE', unicode / 'vendor/hash/sha256/LICENSE'), ('rotate-bits-LICENSE', unicode / 'vendor/hash/rotate-bits/LICENSE.md'),
                       ('json-LICENSE', unicode / 'licenses/LICENSE-jsonhpp'), ('onnxruntime-LICENSE', runtime / 'LICENSE'),
                       ('onnxruntime-ThirdPartyNotices.txt', runtime / 'ThirdPartyNotices.txt')]:
        write(notices / name, path.read_bytes())
    for value in pins['notices']:
        write(notices / value['name'], verified(value).read_bytes())
    write(notices / 'language-attribution.txt', (
        'Language identification: fastText, Facebook Inc. Unmodified lid.176.ftz, CC-BY-SA-3.0.\n'
        'Model/training-data attribution and references: https://fasttext.cc/docs/en/language-identification.html\n'
        'Training sources: Wikipedia, Tatoeba, SETimes. References: arXiv:1607.01759 and arXiv:1612.03651.\n'
        'Character-script sets derive from OpenCC TSCharacters ver.1.1.9; text is never converted.\n'
        'The cased BERT vocabulary comes unchanged from google-bert/bert-base-multilingual-cased (Apache-2.0).\n'
        'The optional entity model is an ONNX Community conversion, attributed to Davlan, under AFL-3.0.\n'
        'Entity weights are not bundled by this builder. User installation must present the model license and obtain acceptance.\n'
    ).encode())
    checks = [os.sys.executable, str(source / 'check-worker.py'), '--executable', str(worker),
              '--tokenizer-executable', str(build / 'bin' / ('tokenizer-reference-check' + suffix)),
              '--vocabulary', str(output / 'clipboard-text-vocab.txt')]
    provenance = {'pins': pins, 'entity': entity, 'runtime': runtime_value, 'unicodeSDK': unicode_value,
                  'cpuOnly': True, 'entityWeightsBundled': False, 'languageWeightsBundled': True,
                  'entityLicenseAcceptanceRequired': True, 'nativeChecksPassed': False, 'realEntityInferenceVerified': False}
    if args.download_test_model:
        model = verified({'name': entity['filename'], 'size': entity['size'], 'sha256': entity['sha256'], 'url': entity['url']})
        checks += ['--model', str(model)]
        provenance['realEntityInferenceVerified'] = True
    subprocess.run(checks, check=True, timeout=180)
    provenance['nativeChecksPassed'] = True
    write(notices / 'provenance.json', (json.dumps(provenance, indent=2) + '\n').encode())
    print('Built verified CPU text worker; language resources bundled, entity weights remain optional', flush=True)


if __name__ == '__main__':
    try:
        main()
    except Exception:
        raise SystemExit('Text worker build/verification failed; inspect bounded build logs')
