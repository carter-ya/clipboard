#!/usr/bin/env python3
"""Exercise development entry installation and real GIO command expansion privately."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

installer = Path(__file__).with_name('install-linux-desktop-entry.py').resolve()
with tempfile.TemporaryDirectory(prefix='clipboard-entry-test-') as directory:
    root = Path(directory)
    for index, name in enumerate(['Clipboard Desktop 中文', 'Clipboard "quoted" $`\\ path']):
        home = root / str(index)
        executable = root / name
        receipt = home / 'launched'
        executable.write_text('#!/usr/bin/python3\nfrom pathlib import Path\nPath(' + repr(str(receipt)) + ').write_text("owned fixture")\n', encoding='utf-8')
        executable.chmod(0o700)
        env = dict(os.environ, XDG_DATA_HOME=str(home), XDG_DATA_DIRS=str(home))
        command = [sys.executable, str(installer), '--executable', str(executable)]
        subprocess.run(command, env=env, check=True, capture_output=True, timeout=10)
        entry = home / 'applications/com.clipboard.desktop.desktop'
        original = entry.read_bytes()
        subprocess.run(command, env=env, check=True, capture_output=True, timeout=10)
        assert entry.read_bytes() == original
        # Launch this test's harmless executable through GIO, checking both
        # desktop-value unescaping and Exec quoting.
        launch = ('from gi.repository import Gio; '
                  'app=Gio.DesktopAppInfo.new_from_filename(' + repr(str(entry)) + '); '
                  'assert app is not None; assert app.launch([], None)')
        subprocess.run([sys.executable, '-c', launch], env=env, check=True, timeout=10)
        deadline = time.monotonic() + 5
        while not receipt.exists() and time.monotonic() < deadline:
            time.sleep(.02)
        assert receipt.read_text() == 'owned fixture', 'Development entry launched the wrong command'
        entry.write_text('[Desktop Entry]\nName=Other owned fixture\n', encoding='utf-8')
        foreign = entry.read_bytes()
        assert subprocess.run(command, env=env, capture_output=True, timeout=10).returncode != 0
        assert entry.read_bytes() == foreign
        entry.unlink()
        target = home / 'unrelated'
        target.write_text('Keep this owned fixture', encoding='utf-8')
        entry.symlink_to(target)
        assert subprocess.run(command, env=env, capture_output=True, timeout=10).returncode != 0
        assert target.read_text() == 'Keep this owned fixture'
    for index, name in enumerate(['Clipboard %f percent', 'Clipboard=invalid', 'Clipboard\ninvalid']):
        executable = root / name
        executable.write_text('#!/bin/sh\nexit 0\n', encoding='utf-8')
        executable.chmod(0o700)
        home = root / ('rejected-' + str(index))
        env = dict(os.environ, XDG_DATA_HOME=str(home), XDG_DATA_DIRS=str(home))
        result = subprocess.run([sys.executable, str(installer), '--executable', str(executable)], env=env, capture_output=True, timeout=10)
        assert result.returncode != 0 and not home.exists(), 'Unsupported path changed application identity'
print('Development entry checks passed: GIO launch, quoting, rejected paths, idempotence, ownership and symlink refusal')
