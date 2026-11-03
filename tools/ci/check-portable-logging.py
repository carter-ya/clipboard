#!/usr/bin/env python3
"""Exercise production logging with absent, invalid, unwritable and live stderr."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def run_windows(executable, receipt, mode, sink):
    import _winapi
    import msvcrt

    startup = subprocess.STARTUPINFO()
    startup.dwFlags = subprocess.STARTF_USESTDHANDLES
    startup.hStdInput = startup.hStdOutput = 0
    descriptor = None
    if mode in ('absent', 'invalid'):
        startup.hStdError = 0 if mode == 'absent' else -1
    else:
        descriptor = os.open(sink, os.O_RDONLY if mode == 'unwritable' else os.O_WRONLY)
        handle = msvcrt.get_osfhandle(descriptor)
        os.set_handle_inheritable(handle, True)
        startup.hStdError = handle
        startup.lpAttributeList = {'handle_list': [handle]}
    process = thread = None
    try:
        process, thread, _, _ = _winapi.CreateProcess(
            str(executable), subprocess.list2cmdline([str(executable), str(receipt)]),
            None, None, descriptor is not None,
            subprocess.CREATE_NO_WINDOW | 0x04000000,  # No system crash dialog.
            None, str(executable.parent), startup)
        if _winapi.WaitForSingleObject(process, 10000) == 258:
            _winapi.TerminateProcess(process, 94)
            _winapi.WaitForSingleObject(process, 5000)
            raise RuntimeError('logging_probe_timeout')
        return _winapi.GetExitCodeProcess(process)
    finally:
        if thread is not None:
            _winapi.CloseHandle(thread)
        if process is not None:
            _winapi.CloseHandle(process)
        if descriptor is not None:
            os.close(descriptor)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', required=True)
    parser.add_argument('--source', type=Path)
    args = parser.parse_args()
    if sys.platform == 'darwin':
        raise SystemExit('portable_backend_probe_requires_non_apple_runtime')
    repo = Path(__file__).resolve().parents[2]
    output = Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    checks = []
    with tempfile.TemporaryDirectory(prefix='logging-', dir=output) as directory:
        root = Path(directory)
        executable = root / ('logging-probe.exe' if os.name == 'nt' else 'logging-probe')
        command = ['swiftc', '-parse-as-library',
                   str(args.source or repo / 'Core/Sources/ClipboardCore/Logging.swift'),
                   str(repo / 'tools/ci/portable-logging-probe.swift'), '-o', str(executable)]
        if os.name == 'nt':
            command += ['-Xlinker', '/SUBSYSTEM:WINDOWS', '-Xlinker', '/ENTRY:mainCRTStartup']
        subprocess.run(command, check=True, timeout=120)
        if os.name == 'nt':
            # Small diagnostic binary only; uses the installed Swift runtime
            # when repeating the regression in a client VM. No UI/clipboard.
            shutil.copy2(executable, output / executable.name)
        modes = ('absent', 'invalid', 'unwritable', 'redirected') if os.name == 'nt' else ('unwritable', 'redirected')
        for mode in modes:
            receipt, sink = root / (mode + '.receipt'), root / (mode + '.stderr')
            sink.touch(exist_ok=False)
            if os.name == 'nt':
                code = run_windows(executable, receipt, mode, sink)
            else:
                # No parent process descriptor is modified.
                with sink.open('rb' if mode != 'redirected' else 'wb') as stream:
                    code = subprocess.run([str(executable), str(receipt)],
                                          stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                          stderr=stream, timeout=10).returncode
            completed = receipt.exists() and receipt.read_bytes() == b'logging-completed\n'
            passed = code == 0 and completed
            if mode == 'redirected':
                data = sink.read_bytes()
                passed = (passed and data.count(b'secret=<private> public=42') == 2
                          and b'synthetic-private-value' not in data)
            checks.append({'mode': mode, 'exitCode': code, 'completed': completed, 'passed': passed})
    result = {'platform': sys.platform, 'checks': checks, 'passed': all(c['passed'] for c in checks)}
    (output / 'results.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result), flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
