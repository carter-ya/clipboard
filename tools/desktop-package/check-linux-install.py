#!/usr/bin/env python3
"""Install/upgrade/uninstall on synthetic profiles in a runtime-only container."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--package', required=True)
parser.add_argument('--probe', required=True)
parser.add_argument('--output', required=True)
args = parser.parse_args()
if shutil.which('swift') is not None:
    raise RuntimeError('Use the runtime-only image; the Swift SDK must not mask missing dependencies')
package, output = Path(args.package).resolve(), Path(args.output).resolve()
output.mkdir(parents=True, exist_ok=True)
checks = []
completed = False


def check(name, condition):
    checks.append({'name': name, 'passed': bool(condition)})
    print(name + ': ' + str(bool(condition)), flush=True)
    if not condition:
        raise RuntimeError(name)


try:
    with tempfile.TemporaryDirectory(prefix='clipboard-install-fixture-') as folder:
        root = Path(folder)
        installed = root / 'install 中文 space'
        command = ['/usr/bin/python3', str(package / 'install.py'), '--prefix', str(installed),
                   '--applications-dir', str(root / 'applications'), '--bin-dir', str(root / 'commands'),
                   '--config-home', str(root / 'config')]
        subprocess.run(command, check=True, timeout=30)
        executable = installed / 'bin/ClipboardDesktop'
        check('per_user_install_creates_desktop_entry_and_command', executable.is_file()
              and (root / 'applications/com.clipboard.desktop.desktop').is_file()
              and (root / 'commands/clipboard-desktop').resolve() == executable.resolve())
        dependencies = subprocess.check_output(['ldd', str(executable)], text=True)
        check('installed_runtime_has_complete_library_closure', 'not found' not in dependencies)
        probe = subprocess.run(['dbus-run-session', '--', 'xvfb-run', '-a', '/usr/bin/python3', args.probe,
                                '--executable', str(executable), '--install-package', str(package), '--lifecycle-cycles', '20',
                                '--output', str(output / 'ui')], timeout=240)
        check('installed_application_passes_native_ui_probe', probe.returncode == 0)
        history_files = list((output / 'ui').glob('history-*/history.json'))
        check('private_history_was_persisted', bool(history_files))
        history = {str(file): hashlib.sha256(file.read_bytes()).hexdigest() for file in history_files}
        config = root / 'config/autostart'
        config.mkdir(parents=True, exist_ok=True)
        startup = config / 'com.clipboard.desktop.desktop'
        startup.write_text('[Desktop Entry]\nExec="' + str(executable) + '" --background\n')
        unrelated = config / 'unrelated.desktop'
        unrelated.write_text('[Desktop Entry]\nName=Unrelated synthetic fixture\n')
        subprocess.run(command, check=True, timeout=30)
        check('upgrade_preserves_history_bytes_and_startup_preference', startup.is_file() and
              all(hashlib.sha256(Path(file).read_bytes()).hexdigest() == digest for file, digest in history.items()))
        # Only recorded package files may be removed. Unknown files stay intact.
        unowned = installed / 'user-created-note.txt'
        unowned.write_text('synthetic user-created file')
        subprocess.run(['/usr/bin/python3', str(installed / 'uninstall.py')], check=True, timeout=30)
        check('uninstall_removes_binaries_shortcut_and_owned_startup', not executable.exists()
              and not (root / 'commands/clipboard-desktop').is_symlink() and not startup.exists())
        check('uninstall_preserves_history_and_unrelated_files', unrelated.is_file() and unowned.is_file()
              and all(hashlib.sha256(Path(file).read_bytes()).hexdigest() == digest for file, digest in history.items()))
        tampered = root / 'tampered'
        shutil.copytree(package, tampered)
        with (tampered / 'bin/ClipboardDesktop').open('ab') as file:
            file.write(b'synthetic-corruption')
        corrupted = command.copy()
        corrupted[1] = str(tampered / 'install.py')
        rejected = subprocess.run(corrupted, capture_output=True, text=True, timeout=30)
        check('corrupted_package_is_rejected_before_installation', rejected.returncode != 0
              and 'Package verification failed' in rejected.stderr)
        completed = True
finally:
    (output / 'results.json').write_text(json.dumps({'passed': completed and all(c['passed'] for c in checks),
                                                    'checks': checks}, indent=2))
