#!/usr/bin/env python3
"""Emulate an older x64 CPU, without loading weights or any user content."""
import argparse
import json
from pathlib import Path
import platform
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--executable', required=True)
    args = parser.parse_args()
    emulator = shutil.which('qemu-x86_64')
    if platform.system() != 'Linux' or platform.machine().lower() not in ('x86_64', 'amd64') or not emulator:
        raise RuntimeError('Native Linux x64 and the explicit emulator are required')
    result = subprocess.run([emulator, '-cpu', 'Nehalem', str(Path(args.executable).resolve(strict=True))],
                            input=b'', capture_output=True, timeout=10)
    if result.returncode != 11 or result.stdout or result.stderr:
        print(json.dumps({'unsupported_cpu_guard_passed': False, 'exitCode': result.returncode,
                          'stdoutBytes': len(result.stdout), 'stderrBytes': len(result.stderr)}), flush=True)
        raise RuntimeError('Unsupported CPU did not exit through its capability guard')
    print(json.dumps({'unsupported_cpu_guard_passed': True, 'emulatedOnly': True,
                      'modelOpened': False}), flush=True)


if __name__ == '__main__':
    try:
        main()
    except Exception:
        raise SystemExit('Unsupported CPU check failed')
