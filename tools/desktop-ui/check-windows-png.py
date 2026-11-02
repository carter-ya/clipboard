"""Build and run the product clipboard C adapter regression on an owned runner."""
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import zlib


def chunk(kind, data):
    return (struct.pack('>I', len(data)) + kind + data
            + struct.pack('>I', zlib.crc32(kind + data)))


def main():
    if os.name != 'nt' or os.environ.get('GITHUB_ACTIONS') != 'true':
        raise RuntimeError('Owned Windows Actions desktop required')
    root = Path(__file__).resolve().parents[2]
    compiler = shutil.which('clang')
    if not compiler:
        raise RuntimeError('Windows SDK clang required')
    with tempfile.TemporaryDirectory(prefix='clipboard-png-', dir=os.environ['RUNNER_TEMP']) as temp:
        directory = Path(temp)
        executable = directory / 'check-windows-png.exe'
        subprocess.run([
            compiler, '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror',
            '-I', str(root / 'Core/Sources/CDesktopClipboard/include'),
            str(root / 'tools/desktop-ui/check-windows-png.c'),
            str(root / 'Core/Sources/CDesktopClipboard/desktop_clipboard.c'),
            '-luser32', '-lshell32', '-lole32', '-lwindowscodecs', '-luuid',
            '-o', str(executable)], check=True, timeout=120)
        # Valid compressed PNG: 64 MiB of decoded pixels exceeds the separately
        # bounded fallback by its header size. Generate rows without a large
        # Python allocation; this must preserve the small original only.
        compressor = zlib.compressobj()
        compressed = bytearray()
        row = bytes(1 + 8192 * 4)
        for _ in range(2048):
            compressed.extend(compressor.compress(row))
        compressed.extend(compressor.flush())
        fixture = directory / 'oversized.png'
        fixture.write_bytes(b'\x89PNG\r\n\x1a\n'
                            + chunk(b'IHDR', struct.pack('>IIBBBBB', 8192, 2048, 8, 6, 0, 0, 0))
                            + chunk(b'IDAT', compressed) + chunk(b'IEND', b''))
        subprocess.run([str(executable), str(fixture)], check=True, timeout=30)


if __name__ == '__main__':
    main()
