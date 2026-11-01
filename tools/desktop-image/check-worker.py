#!/usr/bin/env python3
"""Exercise only synthetic image bytes through the actual native worker."""
import argparse
import json
import math
from pathlib import Path
import struct
import subprocess
import zlib

parser = argparse.ArgumentParser()
parser.add_argument('--executable', required=True)
args = parser.parse_args()
executable = str(Path(args.executable).resolve())
checks = []


def check(name, passed):
    checks.append({'name': name, 'passed': bool(passed)})
    if not passed:
        raise RuntimeError(name)


def png(width, height, *, pixels=True):
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    header = struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)
    rows = (b'\0' + bytes([80, 120, 180]) * width) * height if pixels else b''
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', header) + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b'')


def run(data):
    return subprocess.run([executable], input=data, capture_output=True, timeout=15)


for width, height in [(16, 16), (32768, 1)]:
    result = run(png(width, height))
    check('native_image_' + str(width) + '_bounded_result', result.returncode == 0 and 0 < len(result.stdout) <= 4096)
    value = json.loads(result.stdout)
    labels = value['labels']
    check('native_image_' + str(width) + '_metadata', value['width'] == width and value['height'] == height and len(labels) <= 3 and
          all(isinstance(label['name'], str) and 0 < len(label['name'].encode()) <= 128 and
              math.isfinite(label['confidence']) and 0.1 <= label['confidence'] <= 1 for label in labels) and
          [label['confidence'] for label in labels] == sorted([label['confidence'] for label in labels], reverse=True))
for name, data in [('malformed', b'not a synthetic image'), ('empty', b''),
                   ('pixel_budget', png(32768, 32768, pixels=False)), ('input_budget', b'x' * (16 * 1024 * 1024 + 1))]:
    result = run(data)
    check('native_image_rejects_' + name, result.returncode != 0 and not result.stdout)
print(json.dumps({'passed': all(check['passed'] for check in checks), 'checks': checks}), flush=True)
