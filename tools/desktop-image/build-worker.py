#!/usr/bin/env python3
"""Build a CPU-only, isolated image worker from verified upstream artifacts."""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import shutil
import struct
import subprocess
import tarfile
import tempfile
import time
import urllib.error
import urllib.request
import zipfile

parser = argparse.ArgumentParser()
parser.add_argument('--output', required=True)
parser.add_argument('--cache', required=True)
args = parser.parse_args()
source_root = Path(__file__).resolve().parent
pins = json.loads((source_root / 'upstream.json').read_text())
machine = platform.machine().lower()
architecture = 'x64' if machine in ('amd64', 'x86_64') else 'aarch64' if machine in ('arm64', 'aarch64') else ''
system = 'win' if os.name == 'nt' else 'linux'
if platform.system() not in ('Windows', 'Linux') or not architecture or (system == 'win' and architecture != 'x64'):
    raise RuntimeError('Unsupported native image worker builder')
name = 'onnxruntime-' + system + '-' + architecture + '-1.31.1' + ('.zip' if os.name == 'nt' else '.tgz')
asset = next(value for value in pins['assets'] if value['name'] == name)
output, cache = Path(args.output).resolve(), Path(args.cache).resolve()
output.mkdir(parents=True, exist_ok=True)
cache.mkdir(parents=True, exist_ok=True)


def verified(url, name, digest, maximum, size=None, release_asset_id=None):
    target = cache / name
    if not target.exists():
        for attempt in range(3):
            try:
                request = url
                if attempt and release_asset_id:
                    request = urllib.request.Request(
                        'https://api.github.com/repos/microsoft/onnxruntime/releases/assets/' + str(release_asset_id),
                        headers={'Accept': 'application/octet-stream'})
                with urllib.request.urlopen(request, timeout=60) as response:
                    data = response.read(maximum + 1)
                break
            except urllib.error.HTTPError as error:
                if error.code not in (502, 503, 504) or attempt == 2:
                    raise
                time.sleep(2 ** attempt)
        if len(data) > maximum or hashlib.sha256(data).hexdigest() != digest or (size is not None and len(data) != size):
            raise RuntimeError('Image dependency download failed verification')
        with tempfile.NamedTemporaryFile(dir=cache, delete=False) as pending:
            pending.write(data)
            path = Path(pending.name)
        path.replace(target)
    with target.open('rb') as stream:
        data = stream.read(maximum + 1)
    if len(data) > maximum or hashlib.sha256(data).hexdigest() != digest or (size is not None and len(data) != size):
        raise RuntimeError('Cached image dependency failed verification')
    return data


runtime = verified(asset['url'], name, asset['sha256'], 100 * 1024 * 1024, asset['size'], asset['releaseAssetID'])
models = {name: verified(value['url'], name, value['sha256'], 15 * 1024 * 1024, value['size'])
          for name, value in pins['models'].items()}
texts = {}
for value in pins['texts']:
    url = 'https://raw.githubusercontent.com/onnx/models/' + pins['modelCommit'] + '/' + value['path']
    texts[value['name']] = verified(url, value['name'], value['sha256'], 128 * 1024)
model = models['squeezenet1.1-7.onnx']
lines = texts['synset.txt'].decode('utf-8').splitlines()
if len(lines) != 1000 or any(not re.fullmatch(r'n[0-9]{8} [\x20-\x7e]+', line) for line in lines):
    raise RuntimeError('Invalid pinned image classification labels')
labels = [line.split(' ', 1)[1].split(',')[0] for line in lines]
if any(not label or len(label) > 128 for label in labels):
    raise RuntimeError('Image classification label budget exceeded')

with tempfile.TemporaryDirectory(prefix='image-worker-', dir=output) as temporary:
    stage = Path(temporary)
    sdk = stage / 'sdk'
    sdk.mkdir()
    prefix = 'onnxruntime-' + system + '-' + architecture + '-1.31.1/'
    members = {}
    if os.name == 'nt':
        with zipfile.ZipFile(io.BytesIO(runtime)) as archive:
            for entry in archive.infolist():
                if not entry.is_dir() and (entry.filename.startswith(prefix + 'include/') or
                    entry.filename in [prefix + 'lib/onnxruntime.dll', prefix + 'lib/onnxruntime.lib', prefix + 'lib/onnxruntime_providers_shared.dll',
                                       prefix + 'LICENSE', prefix + 'ThirdPartyNotices.txt']):
                    if entry.file_size > 64 * 1024 * 1024 or (entry.external_attr >> 16) & 0o170000 == 0o120000:
                        raise RuntimeError('Invalid image SDK entry')
                    members[entry.filename] = archive.read(entry)
    else:
        with tarfile.open(fileobj=io.BytesIO(runtime), mode='r:gz') as archive:
            for entry in archive:
                if entry.isfile() and (entry.name.startswith(prefix + 'include/') or
                    entry.name in [prefix + 'lib/libonnxruntime.so.1.31.1', prefix + 'LICENSE', prefix + 'ThirdPartyNotices.txt']):
                    if entry.size > 64 * 1024 * 1024:
                        raise RuntimeError('Invalid image SDK entry')
                    members[entry.name] = archive.extractfile(entry).read()
    for path, data in members.items():
        relative = PurePosixPath(path.removeprefix(prefix))
        if relative.is_absolute() or '..' in relative.parts or '\\' in path:
            raise RuntimeError('Unsafe image SDK path')
        target = sdk.joinpath(*relative.parts)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
    with (stage / 'embedded-model.h').open('w', encoding='ascii') as header:
        header.write('static const unsigned char embedded_model[] =\n')
        for index in range(0, len(model), 512):
            header.write('"' + ''.join('\\x%02x' % value for value in model[index:index + 512]) + '"\n')
        header.write(';\nstatic const char *const class_names[1000] = {\n')
        for label in labels:
            header.write(json.dumps(label) + ',\n')
        header.write('};\n')
    compiler = shutil.which('clang') or shutil.which('cc')
    if not compiler:
        raise RuntimeError('Native compiler required for the image worker')
    command = [compiler, '-O2', '-I', str(sdk / 'include'), '-I', str(stage), str(source_root / 'image-worker.c')]
    if os.name == 'nt':
        library = sdk / 'lib/onnxruntime.dll'
        # Bare .lib names are treated as input files by the clang driver. Ask
        # the linker to resolve system libraries through the Windows SDK paths.
        command += [str(sdk / 'lib/onnxruntime.lib'), '-lole32', '-lwindowscodecs', '-luuid',
                    '-Xlinker', '/SUBSYSTEM:WINDOWS', '-Xlinker', '/ENTRY:mainCRTStartup']
    else:
        library = sdk / 'lib/libonnxruntime.so.1.31.1'
        command += [str(library), '-Wl,-rpath,$ORIGIN', '-lm']
    worker = 'clipboard-image-worker' + ('.exe' if os.name == 'nt' else '')
    subprocess.run(command + ([] if os.name == 'nt' else ['-llept']) + ['-o', str(stage / worker)],
                   check=True, cwd=stage, timeout=120)
    runtime_name = 'onnxruntime.dll' if os.name == 'nt' else 'libonnxruntime.so.1'
    shutil.copy2(library, stage / runtime_name)
    if os.name == 'nt':
        shutil.copy2(sdk / 'lib/onnxruntime_providers_shared.dll', stage / 'onnxruntime_providers_shared.dll')
    reference_worker = stage / ('model-reference-check' + ('.exe' if os.name == 'nt' else ''))
    subprocess.run(command + ['-DCLIPBOARD_IMAGE_MODEL_CHECK', '-o', str(reference_worker)], check=True, cwd=stage, timeout=120)
    # A separate test build checks the actual upstream tensor. It is never shipped.
    with tarfile.open(fileobj=io.BytesIO(models['squeezenet1.1-7.tar.gz']), mode='r:gz') as reference:
        tensors = {}
        for entry in reference:
            if entry.name in ['squeezenet1.1/test_data_set_0/input_0.pb', 'squeezenet1.1/test_data_set_0/output_0.pb']:
                if not entry.isfile() or entry.size > 1024 * 1024:
                    raise RuntimeError('Invalid image reference tensor')
                tensors[PurePosixPath(entry.name).name] = reference.extractfile(entry).read()
    from reference_tensor import float_tensor, reference_image
    input_data = float_tensor(tensors['input_0.pb'], [1, 3, 224, 224])
    expected = struct.unpack('<1000f', float_tensor(tensors['output_0.pb'], [1, 1000]))
    result = subprocess.run([str(reference_worker)], input=input_data, capture_output=True, timeout=15)
    if result.returncode or len(result.stdout) != 4000:
        raise RuntimeError('Native image model reference inference failed')
    actual = struct.unpack('<1000f', result.stdout)
    import math
    if not all(math.isfinite(value) for value in actual) or max(abs(a - b) for a, b in zip(actual, expected)) > 0.001:
        raise RuntimeError('Native image model differs from the upstream reference')
    png, normalized = reference_image(input_data)
    reference_result = subprocess.run([str(reference_worker)], input=normalized, capture_output=True, timeout=15)
    image_result = subprocess.run([str(stage / worker)], input=png, capture_output=True, timeout=15)
    if reference_result.returncode or len(reference_result.stdout) != 4000 or image_result.returncode or len(image_result.stdout) > 4096:
        raise RuntimeError('Image preprocessing reference failed')
    scores = struct.unpack('<1000f', reference_result.stdout)
    maximum = max(scores)
    probabilities = [math.exp(value - maximum) for value in scores]
    total = sum(probabilities)
    chosen = sorted(range(1000), key=lambda index: -probabilities[index])[:3]
    expected_labels = [(labels[index], probabilities[index] / total) for index in chosen if probabilities[index] / total >= 0.1]
    image_value = json.loads(image_result.stdout)
    actual_labels = image_value['labels']
    if not expected_labels or image_value['width'] != 256 or image_value['height'] != 256 or len(actual_labels) != len(expected_labels) or any(
            label['name'] != expected_name or abs(label['confidence'] - probability) > 0.000001
            for label, (expected_name, probability) in zip(actual_labels, expected_labels)):
        raise RuntimeError('Native RGB/crop/normalization or confidence postprocessing differs from the reference')
    notices = output / 'image-model-notices'
    notices.mkdir(exist_ok=True)
    for name in ['LICENSE', 'ThirdPartyNotices.txt']:
        shutil.copy2(sdk / name, notices / ('onnxruntime-' + name))
    for name, data in texts.items():
        (notices / name).write_bytes(data)
    provenance = {'runtime': pins['version'], 'runtime_asset': asset, 'model_commit': pins['modelCommit'],
                  'model': pins['models']['squeezenet1.1-7.onnx'], 'texts': pins['texts'],
                  'cpu_only': True, 'telemetry_disabled': True, 'model_embedded': True,
                  'reference_tensor_verified': True, 'preprocessing_reference_verified': True, 'classifications': 1000,
                  'confidence_threshold': 0.1, 'maximum_labels': 3}
    (notices / 'provenance.json').write_text(json.dumps(provenance, indent=2) + '\n')
    for name in [worker, runtime_name] + (['onnxruntime_providers_shared.dll'] if os.name == 'nt' else []):
        (stage / name).replace(output / name)
print('Built bounded CPU image worker; upstream tensor, model and notices verified', flush=True)
