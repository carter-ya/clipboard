#!/usr/bin/env python3
"""Prove cached fixture preparation needs no SDK/network or worker mutation."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--summary-model', required=True)
parser.add_argument('--entity-model', required=True)
args = parser.parse_args()
repo = Path(__file__).resolve().parents[2]
summary = Path(args.summary_model).resolve()
runner = '''import runpy, subprocess, sys, urllib.request
def forbidden(*args, **kwargs):
    raise RuntimeError('unexpected_model_fixture_network_or_build')
urllib.request.urlopen = forbidden
subprocess.run = forbidden
sys.argv = sys.argv[1:]
runpy.run_path(sys.argv[0], run_name='__main__')
'''
checks = []
with tempfile.TemporaryDirectory(prefix='.clipboard-model-only-', dir=summary.parent) as folder:
    root = Path(folder)
    for component, definition, source in [
        ('desktop-language', 'DesktopLocalLanguageModel.json', summary),
        ('desktop-text', 'DesktopLocalEntityModel.json', Path(args.entity_model).resolve()),
    ]:
        pin = json.loads((repo / 'Core/Sources/ClipboardCore/Resources' / definition).read_text())
        cache, output = root / component / 'cache', root / component / 'output'
        cache.mkdir(parents=True)
        output.mkdir()
        canary = output / 'existing-worker-fixture.txt'
        canary.write_bytes(b'public fixed worker output sentinel')
        cached = cache / (pin['sha256'][:16] + '-' + pin['filename'])
        os.link(source, cached)
        command = [sys.executable, '-c', runner, str(repo / 'tools' / component / 'build-worker.py'),
                   '--output', str(output), '--cache', str(cache), '--download-test-model-only']
        result = subprocess.run(command, capture_output=True, timeout=60)
        untouched = lambda: (list(output.iterdir()) == [canary] and
                             canary.read_bytes() == b'public fixed worker output sentinel')
        valid = result.returncode == 0 and untouched() and list(cache.iterdir()) == [cached]
        checks.append({'name': component + '_cached_only_without_sdk_or_output_changes', 'passed': valid})
        if not valid:
            raise RuntimeError('Cached model-only fixture contract failed')
        # Break our hard link before creating corrupt bytes. Never modify the
        # shared verified source model or any existing worker output.
        cached.unlink()
        cached.write_bytes(b'invalid synthetic cached model')
        refused = subprocess.run(command, capture_output=True, timeout=60)
        valid = refused.returncode != 0 and untouched() and list(cache.iterdir()) == [cached]
        checks.append({'name': component + '_corrupt_cache_refused_without_output_changes', 'passed': valid})
        if not valid:
            raise RuntimeError('Corrupt model-only fixture was not safely refused')
print(json.dumps({'passed': True, 'checks': checks, 'networkAndBuildDisabled': True,
                  'largeWeightsOutsideArtifacts': True}), flush=True)
