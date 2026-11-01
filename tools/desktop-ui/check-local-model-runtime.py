#!/usr/bin/env python3
"""Probe installed local workers without weights, clipboard access or networking."""
import argparse
import json
import os
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', required=True)
    args = parser.parse_args()
    directory = Path(args.directory).resolve(strict=True)
    flags = subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0
    checks = []
    for name in ('clipboard-language-worker', 'clipboard-text-worker'):
        path = directory / (name + ('.exe' if os.name == 'nt' else ''))
        result = subprocess.run([str(path)], input=b'{"task":"capability"}', capture_output=True,
                                timeout=5, creationflags=flags, cwd=directory.parent)
        supported = False
        if result.returncode == 0 and not result.stderr and len(result.stdout) <= 128:
            value = json.loads(result.stdout)
            supported = value == {'available': True} and type(value.get('available')) is bool
        unavailable = name == 'clipboard-language-worker' and result.returncode == 11 and not result.stdout and not result.stderr
        checks.append({'worker': name, 'passed': supported or unavailable, 'supported': supported})
    if any(directory.glob('*.gguf')) or any(directory.glob('*.onnx')):
        raise RuntimeError('Optional large model weights were packaged unexpectedly')
    for component, files, weight_flag in [
            ('language-model', ['LICENSE', 'model-LICENSE', 'model-README.md', 'base-model-README.md'], 'weightsBundled'),
            ('text-model', ['AFL-3.0.txt', 'CC-BY-SA-3.0.txt', 'Google-BERT-README.md', 'Entity-original-README.md',
                            'Entity-converter-README.md', 'language-attribution.txt'], 'entityWeightsBundled')]:
        folder = directory.parent / 'share/licenses' / component
        if not folder.is_dir():
            folder = directory / (component + '-notices')
        metadata = folder / 'provenance.json'
        if not metadata.is_file() or metadata.stat().st_size > 256 * 1024:
            raise RuntimeError('Local model provenance is missing or oversized')
        provenance = json.loads(metadata.read_text(encoding='utf-8'))
        if provenance.get(weight_flag) is not False or provenance.get('cpuOnly') is not True or not all(
                (folder / name).is_file() and 0 < (folder / name).stat().st_size <= 1024 * 1024 for name in files):
            raise RuntimeError('Complete local model licenses and provenance are required')
    resources = [directory / ('ClipboardDesktop_ClipboardDesktop' + suffix) / 'ModelLicenses'
                 for suffix in ('.resources', '.bundle')]
    resources = [folder for folder in resources if folder.is_dir()]
    if len(resources) != 1 or not all((resources[0] / name).is_file() for name in ('Apache-2.0.txt', 'AFL-3.0.txt')):
        raise RuntimeError('Offline license resources are required')
    print(json.dumps({'local_model_runtime_checks': checks, 'optionalWeightsBundled': False,
                      'contentFree': True, 'noticesVerified': True, 'offlineLicensesPresent': True}), flush=True)
    if not all(check['passed'] for check in checks):
        raise RuntimeError('Installed local worker capability failed')


if __name__ == '__main__':
    try:
        main()
    except Exception:
        raise SystemExit('Local model runtime check failed')
