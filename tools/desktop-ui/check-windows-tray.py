"""Compile the production Win32 shell dispatcher into a private native test."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


def main():
    if os.name != 'nt' or os.environ.get('GITHUB_ACTIONS') != 'true':
        raise RuntimeError('Owned Windows Actions runner required')
    root = Path(__file__).resolve().parents[2]
    compiler = shutil.which('clang')
    if not compiler:
        raise RuntimeError('Windows SDK clang required')
    with tempfile.TemporaryDirectory(prefix='clipboard-tray-', dir=os.environ['RUNNER_TEMP']) as temp:
        executable = Path(temp) / 'tray-dispatcher.exe'
        subprocess.run([
            compiler, '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror',
            '-D_CRT_SECURE_NO_WARNINGS',
            '-I', str(root / 'Core/Sources/CDesktopShell/include'),
            str(root / 'tools/desktop-ui/check-windows-tray.c'),
            '-luser32', '-lshell32', '-o', str(executable)], check=True, timeout=120)
        subprocess.run([str(executable)], check=True, timeout=10)


if __name__ == '__main__':
    main()
