#!/usr/bin/env python3
"""Verify the actual PE stack reservation without executing the Windows binary."""
import argparse
import json
from pathlib import Path
import struct

parser = argparse.ArgumentParser()
parser.add_argument('--executable', required=True)
parser.add_argument('--output')
args = parser.parse_args()
with Path(args.executable).open('rb') as file:
    header = file.read(65536)
if len(header) < 64 or header[:2] != b'MZ':
    raise SystemExit('invalid_pe_header')
offset = struct.unpack_from('<I', header, 60)[0]
if (offset + 112 > len(header) or header[offset:offset + 4] != b'PE\0\0' or
        struct.unpack_from('<H', header, offset + 4)[0] != 0x8664 or
        struct.unpack_from('<H', header, offset + 24)[0] != 0x20b):
    raise SystemExit('invalid_x64_pe_header')
reserve, commit = struct.unpack_from('<QQ', header, offset + 24 + 72)
result = {'stackReserveBytes': reserve, 'stackCommitBytes': commit,
          'passed': reserve == 8 * 1024 * 1024 and 0 < commit <= 65536}
if args.output:
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result), flush=True)
raise SystemExit(0 if result['passed'] else 1)
