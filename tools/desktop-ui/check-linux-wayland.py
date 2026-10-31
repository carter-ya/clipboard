#!/usr/bin/env python3
"""Own a headless native Wayland compositor; exchange only synthetic clipboard data."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser()
parser.add_argument('--executable', required=True)
parser.add_argument('--ui-executable')
parser.add_argument('--copy-only', action='store_true', help='Exercise GTK copy-only fallback inside the private Sway UI fixture')
parser.add_argument('--compositor', choices=['sway', 'weston'], default='sway')
parser.add_argument('--output', required=True)
args = parser.parse_args()
out = Path(args.output).resolve()
out.mkdir(parents=True, exist_ok=True)
checks = []
app = peer = compositor = pointer = None
completed = False
log = None


def check(name, condition):
    checks.append({'name': name, 'passed': bool(condition)})
    print(name + ': ' + str(bool(condition)), flush=True)
    if not condition:
        raise RuntimeError(name)


def wait_for(predicate, name, seconds=25):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if app and app.poll() is not None:
            raise RuntimeError('private_application_exited')
        if compositor and compositor.poll() is not None:
            raise RuntimeError('private_compositor_exited')
        try:
            value = predicate()
            if value:
                return value
        except Exception:
            pass
        time.sleep(.1)
    raise RuntimeError(name)


def stop(process):
    if process and process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)


try:
    with tempfile.TemporaryDirectory(prefix='clipboard-wayland-fixture-') as folder:
        root = Path(folder)
        runtime = root / 'runtime'
        runtime.mkdir(mode=0o700)
        env = os.environ.copy()
        env.pop('DISPLAY', None)
        env.pop('WAYLAND_DISPLAY', None)
        env.update(XDG_RUNTIME_DIR=str(runtime), GDK_BACKEND='wayland', GSK_RENDERER='cairo', GTK_A11Y='atspi',
                   CLIPBOARD_PRIVATE_WAYLAND_TEST='1')
        log = open(out / 'application.log', 'wb')
        if args.compositor == 'sway':
            config = root / 'sway.conf'
            config.write_text('output HEADLESS-1 resolution 1280x900\nseat seat0 fallback true\ndefault_border none\nxwayland disable\n')
            env.update(WLR_BACKENDS='headless', WLR_RENDERER='pixman', WLR_LIBINPUT_NO_DEVICES='1')
            compositor = subprocess.Popen(['sway', '-c', str(config)], env=env, stdout=log, stderr=log)
        else:
            compositor = subprocess.Popen(['weston', '--backend=headless-backend.so', '--use-pixman',
                                           '--width=1280', '--height=900', '--socket=wayland-fixture',
                                           '--no-config', '--idle-time=0'], env=env, stdout=log, stderr=log)
        socket = wait_for(lambda: next((p for p in runtime.glob('wayland-*')
                                        if not p.name.endswith('.lock')), None), 'private_wayland_socket')
        env['WAYLAND_DISPLAY'] = socket.name
        if args.copy_only:
            env['SWAYSOCK'] = str(wait_for(lambda: next(runtime.glob('sway-ipc.*.sock'), None), 'private_sway_ipc'))
            tools = Path(__file__).resolve().parent
            protocol = tools / 'protocols/wlr-virtual-pointer-unstable-v1.xml'
            header = root / 'wlr-virtual-pointer-unstable-v1-client-protocol.h'
            implementation = root / 'pointer-protocol.c'
            subprocess.run(['wayland-scanner', 'client-header', str(protocol), str(header)], check=True, timeout=10)
            subprocess.run(['wayland-scanner', 'private-code', str(protocol), str(implementation)], check=True, timeout=10)
            subprocess.run(['cc', str(tools / 'wayland-pointer.c'), str(implementation), '-I', str(root),
                            '-lwayland-client', '-o', str(root / 'pointer')], check=True, timeout=20)
            pointer = subprocess.Popen([str(root / 'pointer')], env=env, stdin=subprocess.PIPE,
                                       stdout=subprocess.PIPE, stderr=log)
            check('private_mouse_device_ready', pointer.stdout.readline() == b'ready\n')
        binary = str(Path(args.executable).resolve())
        if args.compositor == 'sway':
            native = subprocess.run([binary, 'platform-rich-clipboard'], env=env, capture_output=True,
                                    timeout=60, check=True)
            report = json.loads(native.stdout)
            checks.extend(report['checks'])
            check('native_wayland_rich_transport_passes', report['passed'])
            peer = subprocess.Popen(['wl-copy', '--foreground', '--type', 'text/plain;charset=utf-8'],
                                    env=env, stdin=subprocess.PIPE, stdout=log, stderr=log)
            peer.stdin.write('Independent Wayland 中文'.encode())
            peer.stdin.close()
            def published():
                try:
                    return subprocess.check_output(['wl-paste', '--no-newline'], env=env, timeout=2) == 'Independent Wayland 中文'.encode()
                except (subprocess.SubprocessError, OSError):
                    return False
            wait_for(published, 'independent_wl_copy_published')
            readback = subprocess.run([binary, 'rich-clipboard-peer', 'read-text'], env=env,
                                      capture_output=True, timeout=5, check=True)
            check('reads_independent_wl_clipboard_unicode', readback.stdout == b'readback-ok\n')
            stop(peer)
            peer = None
        else:
            native = subprocess.run([binary, 'rich-clipboard-peer', 'probe-restricted'], env=env,
                                    capture_output=True, timeout=10, check=True)
            check('restricted_compositor_does_not_advertise_capture', native.stdout == b'restricted-ok\n')
        if args.ui_executable:
            import pyatspi

            def walk(node, depth=0):
                if depth > 60:
                    return
                try:
                    node.clearCache()
                except Exception:
                    pass
                yield node
                try:
                    for child in node:
                        if child:
                            yield from walk(child, depth + 1)
                except Exception:
                    pass

            def nodes():
                for node in pyatspi.Registry.getDesktop(0):
                    try:
                        if node.get_process_id() == app.pid:
                            return list(walk(node))
                    except Exception:
                        pass
                return []

            def has_text(value):
                return any(node.name == value for node in nodes())

            def click(label):
                def find():
                    for node in nodes():
                        if node.name != label:
                            continue
                        for _ in range(10):
                            if node.getRole() == pyatspi.ROLE_PUSH_BUTTON:
                                return node
                            node = node.parent
                            if node is None:
                                break
                    return None
                control = wait_for(find, 'button_' + label)
                if args.copy_only and label == 'Copy':
                    # GDK's ordinary Wayland clipboard requires an input serial.
                    # Deliver a mouse click in our compositor; no keyboard device
                    # or key event is created, and no host desktop is accessed.
                    bounds = control.queryComponent().getExtents(pyatspi.WINDOW_COORDS)
                    tree = json.loads(subprocess.check_output(['swaymsg', '-t', 'get_tree'], env=env))
                    def client(node):
                        if node.get('pid') == app.pid:
                            return node
                        for child in node.get('nodes', []) + node.get('floating_nodes', []):
                            found = client(child)
                            if found:
                                return found
                        return None
                    window = client(tree)['rect']
                    x, y = window['x'] + bounds.x + bounds.width // 2, window['y'] + bounds.y + bounds.height // 2
                    for operation in [f'seat seat0 cursor set {x} {y}', 'seat seat0 cursor press button1', 'seat seat0 cursor release button1']:
                        response = json.loads(subprocess.check_output(['swaymsg', operation], env=env))
                        if not all(item.get('success') for item in response):
                            raise RuntimeError('private_pointer_action_failed')
                    return
                if not control.queryAction().doAction(0):
                    raise RuntimeError('invoke_' + label)

            history = root / 'history'
            if args.compositor != 'sway':
                raise RuntimeError('The UI fixture requires Sway; Weston headless accessibility remains a manual gate')
            launch = [str(Path(args.ui_executable).resolve()), '--smoke-root', str(history)]
            if args.copy_only:
                launch.append('--smoke-copy-only')
            app = subprocess.Popen(launch, env=env, stdout=log, stderr=log)
            try:
                wait_for(lambda: has_text('Ready') and has_text('3 items'), 'initial_wayland_history')
            except Exception:
                # This desktop contains only our synthetic application.
                print('Fixture accessibility nodes: ' + repr([(n.name, n.getRoleName()) for n in nodes()][:60]), flush=True)
                raise
            check('native_wayland_window_and_controls_visible', True)
            click('Copy')
            wait_for(lambda: has_text('Copied to clipboard'), 'wayland_copy_status')
            check('wayland_copy_action_remains_available', True)
            if args.compositor == 'sway':
                readback = subprocess.check_output(['wl-paste', '--no-newline'], env=env, timeout=5)
                check('ui_copy_has_native_wayland_readback', readback.decode() == 'Release checklist · build, test, publish')
            if not args.copy_only:
                click('Start recording')
                wait_for(lambda: has_text('Recording clipboard'), 'wayland_recording')
                peer = subprocess.Popen([binary, 'rich-clipboard-peer', 'rich'], env=env, stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=log)
                check('independent_wayland_peer_ready', peer.stdout.readline() == b'ready\n')
                wait_for(lambda: has_text('4 items'), 'wayland_rich_item_captured')
                check('native_wayland_ui_captures_rich_item', True)
                subprocess.run(['grim', str(out / 'wayland-history.png')], env=env, check=True, timeout=10)
                peer.stdin.close()
                peer.wait(timeout=5)
                peer = None
                click('Pause recording')
                wait_for(lambda: has_text('Recording paused'), 'wayland_paused')
            else:
                click('Start recording')
                wait_for(lambda: has_text('Clipboard capture is unavailable on this Wayland desktop. Copy remains available.'),
                         'restricted_wayland_explanation')
                check('restricted_ui_explains_capture_limit', has_text('Start recording') and not has_text('Pause recording'))
            def editor():
                return next((n for n in nodes() if 'EditableText' in n.get_interfaces()), None)
            wait_for(editor, 'wayland_search').queryEditableText().setTextContents('中文')
            wait_for(lambda: has_text('1 items'), 'wayland_unicode_search')
            check('native_wayland_unicode_search', True)
            click('Settings')
            wait_for(lambda: has_text('Preferences'), 'wayland_settings')
            click('Back to history')
            wait_for(lambda: has_text('1 items'), 'wayland_search_restored')
            check('wayland_settings_return_preserves_search', True)
    completed = True
finally:
    for process in [peer, app, pointer, compositor]:
        stop(process)
    if log:
        log.close()
    (out / 'results.json').write_text(json.dumps({
        'passed': completed and bool(checks) and all(c['passed'] for c in checks), 'checks': checks,
        'limitations': ['No keyboard input is synthesized. Physical shortcut focus/IME remains unverified.',
                        'Portal protocol fixtures are separate from compositor keyboard integration.']}, indent=2))
